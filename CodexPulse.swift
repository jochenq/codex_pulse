import AppKit
import Foundation
import SQLite3

struct TokenUsage: Codable {
    var input = 0
    var cached = 0
    var output = 0
    var reasoning = 0
    var total = 0
}

struct RequestMetric: Codable {
    let turnID: String
    let timestamp: String
    let model: String
    let effort: String
    let ttftMS: Int
    let durationMS: Int
    let usage: TokenUsage
    let modelCalls: Int?
    let source: String
}

struct LiveRequest {
    let turnID: String
    let timestamp: String
    let model: String
    let effort: String
    let usage: TokenUsage
    let modelCalls: Int
    let source: String
}

struct APICallMetric: Codable {
    let id: String
    let sessionID: String
    let turnID: String
    let timestamp: String
    let model: String
    let effort: String
    let usage: TokenUsage
    let source: String
}

struct ActiveAPICall {
    let id: String
    let sessionID: String
    let turnID: String
    let timestamp: String
    let model: String
    let effort: String
    let status: String
    let source: String
}

private struct PendingTurn {
    var id: String
    var timestamp: String
    var model = "未知"
    var effort = "未知"
    var usage = TokenUsage()
    var baselineUsage = TokenUsage()
    var modelCalls = 0
}

private struct PendingAPIState {
    var timestamp: String
    var status: String
}

private struct ParseResult {
    var completed: [RequestMetric]
    var pending: LiveRequest?
    var apiCalls: [APICallMetric]
    var activeAPI: ActiveAPICall?
}

final class MetricStore {
    private(set) var records: [RequestMetric] = []
    private(set) var apiCalls: [APICallMetric] = []
    private var knownIDs = Set<String>()
    private var knownAPICallIDs = Set<String>()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var scannedModificationDates: [String: Date] = [:]
    private var liveBySource: [String: LiveRequest] = [:]
    private var activeAPIBySource: [String: ActiveAPICall] = [:]
    private var cachedSessionTitles: [String: String] = [:]
    private var titleDatabaseModificationDate: Date?
    private let usageMigrationKey = "turn-token-usage-delta-v1"
    private let modelCallMigrationKey = "turn-model-call-count-v1"
    private let apiCallMigrationKey = "api-call-records-v1"

    var liveRequests: [LiveRequest] {
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return liveBySource.values.filter {
            guard let date = withFractions.date(from: $0.timestamp) ?? plain.date(from: $0.timestamp) else { return false }
            return date >= cutoff
        }.sorted { $0.timestamp > $1.timestamp }
    }

    var activeAPICalls: [ActiveAPICall] {
        let cutoff = Date().addingTimeInterval(-6 * 60 * 60)
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return activeAPIBySource.values.filter {
            guard let date = withFractions.date(from: $0.timestamp) ?? plain.date(from: $0.timestamp) else { return false }
            return date >= cutoff
        }.sorted { $0.timestamp > $1.timestamp }
    }

    let directoryURL: URL
    let recordsURL: URL
    let apiCallsURL: URL
    private let scanStateURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("Codex Pulse", isDirectory: true)
        recordsURL = directoryURL.appendingPathComponent("requests.jsonl")
        apiCallsURL = directoryURL.appendingPathComponent("api-calls.jsonl")
        scanStateURL = directoryURL.appendingPathComponent("scan-state.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: recordsURL.path) {
            FileManager.default.createFile(atPath: recordsURL.path, contents: nil)
        }
        if !FileManager.default.fileExists(atPath: apiCallsURL.path) {
            FileManager.default.createFile(atPath: apiCallsURL.path, contents: nil)
        }
        loadSavedRecords()
        loadSavedAPICalls()
        repairUnknownRecords()
        loadScanState()
    }

    private func loadScanState() {
        guard let data = try? Data(contentsOf: scanStateURL),
              let state = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return }
        scannedModificationDates = state.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveScanState() {
        let state = scannedModificationDates.mapValues(\.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: scanStateURL, options: .atomic)
    }

    private func loadSavedRecords() {
        guard let text = try? String(contentsOf: recordsURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let metric = try? decoder.decode(RequestMetric.self, from: data) else { continue }
            records.append(metric)
            knownIDs.insert(metric.turnID)
        }
        records.sort { $0.timestamp > $1.timestamp }
    }

    private func loadSavedAPICalls() {
        guard let text = try? String(contentsOf: apiCallsURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let metric = try? decoder.decode(APICallMetric.self, from: data) else { continue }
            apiCalls.append(metric)
            knownAPICallIDs.insert(metric.id)
        }
        apiCalls.sort { $0.timestamp > $1.timestamp }
    }

    func sessionTitles() -> [String: String] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let databaseModified = try? databaseURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let walModified = try? walURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let modified = [databaseModified, walModified].compactMap { $0 }.max()
        if modified == titleDatabaseModificationDate, !cachedSessionTitles.isEmpty { return cachedSessionTitles }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return cachedSessionTitles }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, title FROM threads", -1, &statement, nil) == SQLITE_OK,
              let statement else { return cachedSessionTitles }
        defer { sqlite3_finalize(statement) }
        var titles: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let titleText = sqlite3_column_text(statement, 1) else { continue }
            titles[String(cString: idText)] = String(cString: titleText)
        }
        cachedSessionTitles = titles
        titleDatabaseModificationDate = modified
        return titles
    }

    @discardableResult
    func importCodexHistory() -> Int {
        if !UserDefaults.standard.bool(forKey: usageMigrationKey)
            || !UserDefaults.standard.bool(forKey: modelCallMigrationKey)
            || !UserDefaults.standard.bool(forKey: apiCallMigrationKey) {
            return rebuildAllHistoryWithTurnDeltas()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = values?.contentModificationDate ?? .distantPast
                if scannedModificationDates[file.path] != modified {
                    scannedModificationDates[file.path] = modified
                    files.append(file)
                }
            }
        }

        var imported: [RequestMetric] = []
        var importedAPICalls: [APICallMetric] = []
        for file in files {
            autoreleasepool {
                let parsed = parse(file: file)
                imported.append(contentsOf: parsed.completed)
                importedAPICalls.append(contentsOf: parsed.apiCalls)
                liveBySource[file.path] = parsed.pending
                activeAPIBySource[file.path] = parsed.activeAPI
            }
        }
        imported = imported.filter { !knownIDs.contains($0.turnID) }
        imported.sort { $0.timestamp < $1.timestamp }
        for metric in imported { append(metric) }
        records.sort { $0.timestamp > $1.timestamp }
        importedAPICalls = importedAPICalls.filter { !knownAPICallIDs.contains($0.id) }
        importedAPICalls.sort { $0.timestamp < $1.timestamp }
        for metric in importedAPICalls { appendAPICall(metric) }
        apiCalls.sort { $0.timestamp > $1.timestamp }
        saveScanState()
        return imported.count
    }

    private func rebuildAllHistoryWithTurnDeltas() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        var rebuiltByID: [String: RequestMetric] = [:]
        var rebuiltAPICallsByID: [String: APICallMetric] = [:]
        var rebuiltLive: [String: LiveRequest] = [:]
        var rebuiltActiveAPIs: [String: ActiveAPICall] = [:]
        var rebuiltDates: [String: Date] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                autoreleasepool {
                    let parsed = parse(file: file)
                    for metric in parsed.completed { rebuiltByID[metric.turnID] = metric }
                    for metric in parsed.apiCalls { rebuiltAPICallsByID[metric.id] = metric }
                    if let pending = parsed.pending { rebuiltLive[file.path] = pending }
                    if let activeAPI = parsed.activeAPI { rebuiltActiveAPIs[file.path] = activeAPI }
                    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    rebuiltDates[file.path] = values?.contentModificationDate ?? .distantPast
                }
            }
        }
        records = Array(rebuiltByID.values).sorted { $0.timestamp > $1.timestamp }
        knownIDs = Set(rebuiltByID.keys)
        apiCalls = Array(rebuiltAPICallsByID.values).sorted { $0.timestamp > $1.timestamp }
        knownAPICallIDs = Set(rebuiltAPICallsByID.keys)
        liveBySource = rebuiltLive
        activeAPIBySource = rebuiltActiveAPIs
        scannedModificationDates = rebuiltDates
        rewriteRecords()
        rewriteAPICalls()
        saveScanState()
        UserDefaults.standard.set(true, forKey: usageMigrationKey)
        UserDefaults.standard.set(true, forKey: modelCallMigrationKey)
        UserDefaults.standard.set(true, forKey: apiCallMigrationKey)
        return records.count
    }

    private func parse(file: URL) -> ParseResult {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return ParseResult(completed: [], pending: nil, apiCalls: [], activeAPI: nil)
        }
        var pending: PendingTurn?
        var pendingAPIState: PendingAPIState?
        var result: [RequestMetric] = []
        var apiCallResult: [APICallMetric] = []
        var sessionID = file.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init) ?? file.lastPathComponent
        var lastModel: String?
        var lastEffort: String?
        var sessionUsage = TokenUsage()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let timestamp = object["timestamp"] as? String ?? ""
            guard let payload = object["payload"] as? [String: Any] else { continue }

            if type == "session_meta" {
                sessionID = payload["id"] as? String ?? payload["session_id"] as? String ?? sessionID
                continue
            }

            if type == "event_msg", let eventType = payload["type"] as? String {
                switch eventType {
                case "task_started":
                    if let id = payload["turn_id"] as? String {
                        var turn = PendingTurn(id: id, timestamp: timestamp)
                        turn.model = lastModel ?? turn.model
                        turn.effort = lastEffort ?? turn.effort
                        turn.baselineUsage = sessionUsage
                        pending = turn
                        pendingAPIState = PendingAPIState(timestamp: timestamp, status: "请求中")
                    }
                case "token_count":
                    guard var turn = pending,
                          let info = payload["info"] as? [String: Any],
                          let rawUsage = info["total_token_usage"] as? [String: Any] else { continue }
                    let cumulative = TokenUsage(
                        input: int(rawUsage["input_tokens"]),
                        cached: int(rawUsage["cached_input_tokens"]),
                        output: int(rawUsage["output_tokens"]),
                        reasoning: int(rawUsage["reasoning_output_tokens"]),
                        total: int(rawUsage["total_tokens"])
                    )
                    sessionUsage = cumulative
                    turn.usage = usageDelta(cumulative, since: turn.baselineUsage)
                    if let lastUsage = info["last_token_usage"] as? [String: Any],
                       int(lastUsage["total_tokens"]) > 0 {
                        turn.modelCalls += 1
                        apiCallResult.append(APICallMetric(
                            id: "\(sessionID):\(timestamp)", sessionID: sessionID, turnID: turn.id,
                            timestamp: timestamp, model: turn.model, effort: turn.effort,
                            usage: TokenUsage(
                                input: int(lastUsage["input_tokens"]),
                                cached: int(lastUsage["cached_input_tokens"]),
                                output: int(lastUsage["output_tokens"]),
                                reasoning: int(lastUsage["reasoning_output_tokens"]),
                                total: int(lastUsage["total_tokens"])
                            ),
                            source: file.path
                        ))
                        pendingAPIState = PendingAPIState(timestamp: timestamp, status: "请求中")
                    }
                    pending = turn
                case "task_complete":
                    guard let turn = pending,
                          let id = payload["turn_id"] as? String,
                          id == turn.id else { continue }
                    result.append(RequestMetric(
                        turnID: id,
                        timestamp: turn.timestamp.isEmpty ? timestamp : turn.timestamp,
                        model: turn.model,
                        effort: turn.effort,
                        ttftMS: int(payload["time_to_first_token_ms"]),
                        durationMS: int(payload["duration_ms"]),
                        usage: turn.usage,
                        modelCalls: turn.modelCalls,
                        source: file.path
                    ))
                    pending = nil
                    pendingAPIState = nil
                default:
                    break
                }
            } else if type == "turn_context" {
                if let model = payload["model"] as? String { lastModel = model }
                if let effort = payload["effort"] as? String { lastEffort = effort }
                let id = payload["turn_id"] as? String
                if var turn = pending, id == nil || id == turn.id {
                    turn.model = payload["model"] as? String ?? turn.model
                    turn.effort = payload["effort"] as? String ?? turn.effort
                    pending = turn
                }
            } else if type == "response_item", pending != nil, let itemType = payload["type"] as? String {
                switch itemType {
                case "custom_tool_call", "function_call":
                    pendingAPIState?.status = "工具中"
                case "custom_tool_call_output", "function_call_output":
                    pendingAPIState = PendingAPIState(timestamp: timestamp, status: "请求中")
                case "reasoning":
                    pendingAPIState?.status = "响应中"
                case "message" where (payload["role"] as? String) == "assistant":
                    pendingAPIState?.status = "响应中"
                default:
                    break
                }
            }
        }
        let live = pending.map {
            LiveRequest(
                turnID: $0.id,
                timestamp: $0.timestamp,
                model: $0.model,
                effort: $0.effort,
                usage: $0.usage,
                modelCalls: $0.modelCalls,
                source: file.path
            )
        }
        let activeAPI = pending.flatMap { turn in
            pendingAPIState.map {
                ActiveAPICall(id: "active:\(sessionID):\(turn.id):\($0.timestamp)", sessionID: sessionID,
                              turnID: turn.id, timestamp: $0.timestamp, model: turn.model,
                              effort: turn.effort, status: $0.status, source: file.path)
            }
        }
        return ParseResult(completed: result, pending: live, apiCalls: apiCallResult, activeAPI: activeAPI)
    }

    private func repairUnknownRecords() {
        let unknown = records.filter { $0.model == "未知" || $0.effort == "未知" }
        guard !unknown.isEmpty else { return }
        var replacements: [String: RequestMetric] = [:]
        for source in Set(unknown.map(\.source)) {
            let parsed = parse(file: URL(fileURLWithPath: source))
            for metric in parsed.completed where metric.model != "未知" || metric.effort != "未知" {
                replacements[metric.turnID] = metric
            }
        }
        guard !replacements.isEmpty else { return }
        var changed = false
        records = records.map { record in
            guard (record.model == "未知" || record.effort == "未知"),
                  let replacement = replacements[record.turnID] else { return record }
            changed = true
            return replacement
        }
        if changed { rewriteRecords() }
    }

    private func rewriteRecords() {
        var data = Data()
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let encoded = try? encoder.encode(record) else { continue }
            data.append(encoded)
            data.append(0x0a)
        }
        try? data.write(to: recordsURL, options: .atomic)
    }

    private func rewriteAPICalls() {
        var data = Data()
        for record in apiCalls.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let encoded = try? encoder.encode(record) else { continue }
            data.append(encoded)
            data.append(0x0a)
        }
        try? data.write(to: apiCallsURL, options: .atomic)
    }

    private func append(_ metric: RequestMetric) {
        guard knownIDs.insert(metric.turnID).inserted,
              let data = try? encoder.encode(metric) else { return }
        records.append(metric)
        if let handle = try? FileHandle(forWritingTo: recordsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([0x0a]))
        }
    }

    private func appendAPICall(_ metric: APICallMetric) {
        guard knownAPICallIDs.insert(metric.id).inserted,
              let data = try? encoder.encode(metric) else { return }
        apiCalls.append(metric)
        if let handle = try? FileHandle(forWritingTo: apiCallsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([0x0a]))
        }
    }
}

final class RateLimitReader {
    struct Snapshot {
        var primaryUsed: Int?
        var primaryMinutes: Int?
        var primaryReset: Date?
        var secondaryUsed: Int?
        var secondaryMinutes: Int?
        var secondaryReset: Date?
        var plan: String?
        var credits: Double?
        var resetCreditCount: Int?
        var resetCreditExpiry: Date?
    }

    func read(completion: @escaping (Snapshot?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let paths = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ]
            guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                completion(nil); return
            }
            let process = Process()
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch { completion(nil); return }

            let messages: [[String: Any]] = [
                [
                    "id": 0,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "codex_pulse_monitor",
                            "title": "Codex Pulse Monitor",
                            "version": "2.10.3"
                        ]
                    ]
                ],
                ["method": "initialized", "params": [:]],
                ["id": 1, "method": "account/rateLimits/read", "params": [:]]
            ]
            for message in messages {
                if let data = try? JSONSerialization.data(withJSONObject: message) {
                    input.fileHandleForWriting.write(data + Data([0x0a]))
                }
            }
            let response = DispatchSemaphore(value: 0)
            let stateQueue = DispatchQueue(label: "com.codexpulse.rate-limit-response")
            var received = Data()
            var decoded: Snapshot?
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let self else { return }
                stateQueue.sync {
                    received.append(chunk)
                    if decoded == nil, let snapshot = self.decode(received) {
                        decoded = snapshot
                        response.signal()
                    }
                }
            }
            _ = response.wait(timeout: .now() + 12)
            output.fileHandleForReading.readabilityHandler = nil
            let snapshot = stateQueue.sync { decoded }
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            completion(snapshot)
        }
    }

    private func decode(_ data: Data) -> Snapshot? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let bytes = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any] else { continue }
            let primary = limits["primary"] as? [String: Any]
            let secondary = limits["secondary"] as? [String: Any]
            let credits = limits["credits"] as? [String: Any]
            let resetSummary = result["rateLimitResetCredits"] as? [String: Any]
            let resetCredits = resetSummary?["credits"] as? [[String: Any]]
            let resetExpiry = resetCredits?.compactMap { dateValue($0["expiresAt"] ?? $0["expires_at"]) }.min()
            return Snapshot(
                primaryUsed: intOptional(primary?["usedPercent"] ?? primary?["used_percent"]),
                primaryMinutes: intOptional(primary?["windowDurationMins"] ?? primary?["window_duration_mins"]),
                primaryReset: dateValue(primary?["resetsAt"] ?? primary?["resets_at"]),
                secondaryUsed: intOptional(secondary?["usedPercent"] ?? secondary?["used_percent"]),
                secondaryMinutes: intOptional(secondary?["windowDurationMins"] ?? secondary?["window_duration_mins"]),
                secondaryReset: dateValue(secondary?["resetsAt"] ?? secondary?["resets_at"]),
                plan: (limits["planType"] ?? limits["plan_type"]) as? String,
                credits: doubleOptional(credits?["balance"]),
                resetCreditCount: intOptional(resetSummary?["availableCount"] ?? resetSummary?["available_count"]),
                resetCreditExpiry: resetExpiry
            )
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MetricStore()
    private let rateReader = RateLimitReader()
    private var snapshot: RateLimitReader.Snapshot?
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var liveTimer: Timer?
    private var isRefreshing = false
    private var isLivePolling = false
    private let storeQueue = DispatchQueue(label: "com.codexpulse.metric-store", qos: .utility)
    private var statsController: StatsWindowController?
    private var popover: NSPopover!
    private var popoverController: StatusPopoverController!
    private var hasLoadedOnce = false
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Codex Pulse")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " loading"
        popoverController = StatusPopoverController()
        popoverController.onRefresh = { [weak self] in self?.refresh() }
        popoverController.onOpenDashboard = { [weak self] in self?.popover.performClose(nil); self?.showStats() }
        popoverController.onQuit = { NSApp.terminate(nil) }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = popoverController
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.popover.performClose(nil) }
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollLiveMetrics() }
        if CommandLine.arguments.contains("--show-stats") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showStats() }
        }
        if CommandLine.arguments.contains("--show-popover") {
            popover.behavior = .applicationDefined
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        popoverController.setRefreshing(true)
        if !hasLoadedOnce {
            statusItem.button?.title = " loading"
            popoverController.setLoading()
        }
        storeQueue.async { [weak self] in
            guard let self else { return }
            _ = self.store.importCodexHistory()
            self.rateReader.read { snapshot in
                DispatchQueue.main.async {
                    self.snapshot = snapshot ?? self.snapshot
                    self.isRefreshing = false
                    self.hasLoadedOnce = true
                    self.updateUI()
                    if CommandLine.arguments.contains("--show-popover"), !self.popover.isShown {
                        self.togglePopover()
                    }
                }
            }
        }
    }

    private func pollLiveMetrics() {
        guard statsController?.isLiveConsoleVisible == true, !isLivePolling else { return }
        isLivePolling = true
        storeQueue.async { [weak self] in
            guard let self else { return }
            _ = self.store.importCodexHistory()
            let records = self.store.records
            let apiCalls = self.store.apiCalls
            let activeAPICalls = self.store.activeAPICalls
            let titles = self.store.sessionTitles()
            DispatchQueue.main.async {
                self.statsController?.update(records: records, apiCalls: apiCalls,
                                             activeAPICalls: activeAPICalls, sessionTitles: titles)
                self.isLivePolling = false
            }
        }
    }

    @objc private func togglePopover() {
        guard hasLoadedOnce, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updateUI()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateUI() {
        statsController?.update(records: store.records, apiCalls: store.apiCalls,
                                activeAPICalls: store.activeAPICalls, sessionTitles: store.sessionTitles())
        let calendar = Calendar.current
        let todayRecords = store.records.filter { record in
            guard let date = requestMetricDate(record.timestamp) else { return false }
            return calendar.isDateInToday(date)
        }
        let todayCalls = todayRecords.reduce(0) { $0 + ($1.modelCalls ?? 0) }
        let todayTokens = todayRecords.reduce(0) { $0 + $1.usage.total }
        popoverController.update(snapshot: snapshot, todayCalls: todayCalls, todayTokens: todayTokens,
                                 todayCost: summedAPICost(todayRecords), refreshedAt: Date())
        if let used = snapshot?.secondaryUsed ?? snapshot?.primaryUsed {
            statusItem.button?.title = " \(max(0, 100 - used))%"
        } else {
            statusItem.button?.title = " --"
        }
    }

    @objc private func openRecords() {
        NSWorkspace.shared.activateFileViewerSelecting([store.recordsURL])
    }

    @objc private func showStats() {
        if statsController == nil {
            statsController = StatsWindowController(records: store.records, apiCalls: store.apiCalls,
                                                    activeAPICalls: store.activeAPICalls, sessionTitles: store.sessionTitles())
        } else {
            statsController?.update(records: store.records, apiCalls: store.apiCalls,
                                    activeAPICalls: store.activeAPICalls, sessionTitles: store.sessionTitles())
        }
        statsController?.showOverview()
        statsController?.showWindow(nil)
        statsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rateLine(label: String, used: Int?, reset: Date?) -> String {
        guard let used else { return "\(label)：暂无数据" }
        let remaining = max(0, 100 - used)
        let resetText = reset.map { " · \(dateFormatter.string(from: $0)) 重置" } ?? ""
        return "\(label)：已用 \(used)% · 剩余 \(remaining)%\(resetText)"
    }
}

private let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"; return f
}()

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()

private let plainISOFormatter = ISO8601DateFormatter()
private func requestMetricDate(_ value: String) -> Date? { isoFormatter.date(from: value) ?? plainISOFormatter.date(from: value) }

private func int(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? 0 }
    return 0
}

private func usageDelta(_ current: TokenUsage, since baseline: TokenUsage) -> TokenUsage {
    guard current.total >= baseline.total else { return current }
    return TokenUsage(
        input: max(0, current.input - baseline.input),
        cached: max(0, current.cached - baseline.cached),
        output: max(0, current.output - baseline.output),
        reasoning: max(0, current.reasoning - baseline.reasoning),
        total: max(0, current.total - baseline.total)
    )
}

private func intOptional(_ value: Any?) -> Int? {
    guard value != nil else { return nil }
    return int(value)
}

private func doubleOptional(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func dateValue(_ value: Any?) -> Date? {
    guard let seconds = doubleOptional(value) else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

func compactNumber(_ value: Int) -> String {
    let absolute = abs(Double(value))
    let sign = value < 0 ? "-" : ""
    let divisor: Double
    let suffix: String
    if absolute >= 1_000_000_000 {
        divisor = 1_000_000_000; suffix = "B"
    } else if absolute >= 1_000_000 {
        divisor = 1_000_000; suffix = "M"
    } else if absolute >= 1_000 {
        divisor = 1_000; suffix = "k"
    } else {
        return "\(value)"
    }
    let scaled = absolute / divisor
    let decimals = scaled >= 100 ? 0 : (scaled >= 10 ? 1 : 2)
    var text = String(format: "%.*f", decimals, scaled)
    while text.contains(".") && text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return sign + text + suffix
}
private func seconds(_ ms: Int) -> String { String(format: "%.2fs", Double(ms) / 1000) }
private func formatCredits(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "--" }
private func windowLabel(_ minutes: Int?) -> String {
    guard let minutes else { return "额度" }
    if minutes % 10080 == 0 { return "\(minutes / 10080 * 7) 天" }
    if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
    return "\(minutes) 分钟"
}
private func shortDate(_ value: String) -> String {
    guard let date = isoFormatter.date(from: value) else { return value }
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: date)
}

@main
struct CodexPulseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
