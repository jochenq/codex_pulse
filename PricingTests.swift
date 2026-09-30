#if PRICING_TESTS
import Foundation
import SQLite3

@main
struct PricingTests {
    static func main() {
        runPricingRegressionTests()
        StatsWindowController.runOverviewRegressionTests()
        runIncrementalParserRegressionTest()
        runRuntimeServiceTierRegressionTest()
        print("Pricing and incremental parser regression tests passed")
    }

    private static func runIncrementalParserRegressionTest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pulse-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let started = """
        {"timestamp":"2026-09-23T08:00:00Z","type":"session_meta","payload":{"id":"test-session"}}
        {"timestamp":"2026-09-23T08:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"test-turn"}}

        """
        try! started.write(to: file, atomically: true, encoding: .utf8)
        let store = MetricStore(directoryURL: directory.appendingPathComponent("store"), logDatabaseURLs: [])
        let first = store.parseForTesting(file: file)
        precondition(first.completedCount == 0 && first.active)

        let completed = """
        {"timestamp":"2026-09-23T08:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"test-turn","duration_ms":1000,"time_to_first_token_ms":500}}

        """
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.seekToEnd()
        let completedBytes = Data(completed.utf8)
        let midpoint = completedBytes.count / 2
        try! handle.write(contentsOf: completedBytes.prefix(midpoint))
        let partial = store.parseForTesting(file: file)
        precondition(partial.completedCount == 0 && partial.active)
        try! handle.write(contentsOf: completedBytes.suffix(from: midpoint))
        try! handle.close()
        let second = store.parseForTesting(file: file)
        precondition(second.completedCount == 1 && !second.active)
        let third = store.parseForTesting(file: file)
        precondition(third.completedCount == 0 && !third.active, "incremental states: \(first), \(second), \(third)")
    }

    private static func runRuntimeServiceTierRegressionTest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-pulse-tier-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("logs.sqlite")
        var database: OpaquePointer?
        precondition(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        func sql(_ query: String) {
            precondition(sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK)
        }
        sql("CREATE TABLE logs (id INTEGER PRIMARY KEY, ts INTEGER, ts_nanos INTEGER, thread_id TEXT, target TEXT, feedback_log_body TEXT)")
        let base = Int(ISO8601DateFormatter().date(from: "2026-09-30T15:00:00Z")!.timeIntervalSince1970)
        func insert(_ id: Int, _ seconds: Int, _ tier: String) {
            sql("INSERT INTO logs VALUES (\(id), \(base + seconds), 0, 'session-a', 'feedback_tags', 'turn{turn_id=turn-a}: tags_json={\"service_tier\":\"\(tier)\"}')")
        }
        insert(1, 1, "priority")
        let tiers = RuntimeServiceTiers(databaseURLs: [databaseURL])
        precondition(tiers.refresh())
        precondition(!tiers.refresh(), "unchanged logs must not trigger repair")
        precondition(tiers.tier(sessionID: "session-a", turnID: "turn-a", timestamp: "2026-09-30T15:00:00.000Z") == nil)
        precondition(tiers.tier(sessionID: "session-a", turnID: "turn-a", timestamp: "2026-09-30T15:00:02.000Z") == "priority")
        precondition(tiers.tier(sessionID: "session-b", turnID: "turn-a", timestamp: "2026-09-30T15:00:02.000Z") == nil)
        precondition(tiers.tier(sessionID: "session-a", turnID: "turn-b", timestamp: "2026-09-30T15:00:02.000Z") == nil)
        insert(2, 5, "default")
        precondition(tiers.refresh())
        precondition(tiers.tier(sessionID: "session-a", turnID: "turn-a", timestamp: "2026-09-30T15:00:02.000Z") == "priority")
        precondition(tiers.tier(sessionID: "session-a", turnID: "turn-a", timestamp: "2026-09-30T15:00:06.000Z") == "default")
        insert(3, 6, "default")
        precondition(!tiers.refresh(), "repeated tier must not reprocess history")

        let file = directory.appendingPathComponent("session.jsonl")
        let events = """
        {"timestamp":"2026-09-30T15:00:00.000Z","type":"session_meta","payload":{"id":"session-a"}}
        {"timestamp":"2026-09-30T15:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
        {"timestamp":"2026-09-30T15:00:00.000Z","type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol","effort":"high"}}
        {"timestamp":"2026-09-30T15:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}

        """
        try! events.write(to: file, atomically: true, encoding: .utf8)
        let store = MetricStore(directoryURL: directory.appendingPathComponent("store"), logDatabaseURLs: [databaseURL])
        let parsed = store.parseForTesting(file: file)
        precondition(parsed.serviceTiers == ["priority"], "missing JSONL tier must use actual runtime tier")
        precondition(parsed.activeTier == "priority", "live requests must also show Fast")
    }
}
#endif
