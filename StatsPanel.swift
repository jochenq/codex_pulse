import AppKit
import Foundation

private struct GroupStats {
    let model: String
    let effort: String
    let modelCalls: Int
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int
    let total: Int
    let valueUSD: Double?
    let typicalTTFT: Int
    let slowerTTFT: Int
    let averageDuration: Int

    var cacheRate: Double { input > 0 ? Double(cached) / Double(input) : 0 }
}

private struct DailyPoint {
    let date: Date
    let tokens: Int
    let modelCalls: Int
}

private struct ConsoleRow {
    let isLive: Bool
    let turnID: String
    let timestamp: String
    let model: String
    let effort: String
    let ttftMS: Int?
    let durationMS: Int
    let usage: TokenUsage
    let modelCalls: Int
}

final class StatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var allRecords: [RequestMetric] = []
    private var liveRequests: [LiveRequest] = []
    private var filteredRecords: [RequestMetric] = []
    private var groupRows: [GroupStats] = []
    private var consoleRows: [ConsoleRow] = []

    private let rangePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let effortPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let consoleTable = NSTableView()
    private let chartView = DailyTokenChartView()
    private let tabs = NSTabView()
    private var summaryValues: [NSTextField] = []
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let consoleStatusLabel = NSTextField(labelWithString: "")

    var isLiveConsoleVisible: Bool {
        window?.isVisible == true && (tabs.selectedTabViewItem?.identifier as? String) == "console"
    }

    init(records: [RequestMetric], liveRequests: [LiveRequest]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Pulse"
        window.minSize = NSSize(width: 920, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        update(records: records, liveRequests: liveRequests)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(records: [RequestMetric], liveRequests: [LiveRequest]) {
        allRecords = records
        self.liveRequests = liveRequests
        rebuildFilterChoices()
        applyFilters()
        rebuildConsole()
    }

    func showOverview() {
        tabs.selectTabViewItem(withIdentifier: "overview")
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let overview = NSView()
        let overviewItem = NSTabViewItem(identifier: "overview")
        overviewItem.label = "统计概览"
        overviewItem.view = overview
        tabs.addTabViewItem(overviewItem)

        let console = NSView()
        let consoleItem = NSTabViewItem(identifier: "console")
        consoleItem.label = "实时控制台"
        consoleItem.view = console
        tabs.addTabViewItem(consoleItem)
        tabs.selectTabViewItem(at: 0)

        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        buildOverview(in: overview)
        buildConsole(in: console)
    }

    private func buildOverview(in content: NSView) {
        let title = NSTextField(labelWithString: "Codex 请求统计")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        rangePopup.addItems(withTitles: ["今日", "最近 7 天", "最近 30 天", "全部时间"])
        rangePopup.selectItem(at: 0)
        rangePopup.target = self
        rangePopup.action = #selector(filterChanged)
        modelPopup.target = self
        modelPopup.action = #selector(filterChanged)
        effortPopup.target = self
        effortPopup.action = #selector(filterChanged)

        let filters = NSStackView(views: [
            labeledControl("范围", rangePopup),
            labeledControl("模型", modelPopup),
            labeledControl("推理等级", effortPopup)
        ])
        filters.orientation = .horizontal
        filters.spacing = 14
        filters.alignment = .centerY

        let header = NSStackView(views: [titleStack, NSView(), filters])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let metricDefinitions: [(String, String?)] = [
            ("模型调用数", "每次产生非零 last_token_usage 的底层模型调用；一个 Codex 任务通常包含多次模型调用"),
            ("总 Token", nil),
            ("价值相当于", "计算方式：（总输入 − 缓存输入）× 输入价 + 缓存输入 × 缓存价 + 输出 × 输出价；不代表订阅套餐的实际账单"),
            ("典型首响应", "一半请求的首响应时间不超过这个值"),
            ("较慢请求总耗时", "95% 的请求总耗时不超过这个值"),
            ("缓存命中率", "输入 Token 中由缓存直接复用的比例"),
            ("推理 Token 占比", "输出 Token 中用于模型推理的比例")
        ]
        var cards: [NSView] = []
        for (name, help) in metricDefinitions {
            let (box, value) = metricBox(name, help: help)
            cards.append(box)
            summaryValues.append(value)
        }
        let summaryGrid = NSGridView(views: [Array(cards[0..<4]), Array(cards[4..<7]) + [NSView()]])
        summaryGrid.rowSpacing = 10
        summaryGrid.columnSpacing = 10
        for index in 0..<4 { summaryGrid.column(at: index).xPlacement = .fill }
        for card in cards.dropFirst() { card.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true }

        let chartTitle = sectionTitle("每日 Token 趋势（悬浮查看明细）")
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let tableTitle = sectionTitle("按模型 × 推理等级")
        let termHelp = NSTextField(labelWithString: "典型：一半请求不超过 · 较慢：95% 请求不超过")
        termHelp.font = .systemFont(ofSize: 11)
        termHelp.textColor = .secondaryLabelColor
        let tableHeader = NSStackView(views: [tableTitle, NSView(), termHelp])
        tableHeader.orientation = .horizontal
        tableHeader.alignment = .centerY

        configureStatsTable()
        let scroll = makeScrollView(for: tableView)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true

        let stack = NSStackView(views: [header, summaryGrid, chartTitle, chartView, tableHeader, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartTitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func buildConsole(in content: NSView) {
        let title = NSTextField(labelWithString: "实时请求控制台")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        consoleStatusLabel.font = .systemFont(ofSize: 12)
        consoleStatusLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [title, consoleStatusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let explanation = NSTextField(labelWithString: "所有请求按包含年份的完整开始时间倒序排列；今天省略日期，今年省略年份。")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        configureConsoleTable()
        let scroll = makeScrollView(for: consoleTable)

        let stack = NSStackView(views: [header, explanation, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func labeledControl(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func metricBox(_ title: String, help: String?) -> (NSBox, NSTextField) {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .controlBackgroundColor
        box.toolTip = help
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let value = NSTextField(labelWithString: "--")
        value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let inner = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -12),
                stack.centerYAnchor.constraint(equalTo: inner.centerYAnchor)
            ])
        }
        return (box, value)
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeScrollView(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func configureStatsTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 27
        addColumns([
            ("group", "模型 / 推理等级", 185), ("count", "模型调用", 78),
            ("total", "总 Token", 82), ("value", "价值相当于", 90), ("input", "输入", 78),
            ("output", "输出", 70), ("reasoning", "推理", 70),
            ("typical", "典型首响应", 92), ("slower", "较慢首响应", 92),
            ("duration", "平均耗时", 82), ("cache", "缓存命中", 78)
        ], to: tableView)
    }

    private func configureConsoleTable() {
        consoleTable.delegate = self
        consoleTable.dataSource = self
        consoleTable.usesAlternatingRowBackgroundColors = true
        consoleTable.rowHeight = 27
        addColumns([
            ("live_status", "状态", 78), ("live_time", "开始时间", 160),
            ("live_model", "模型", 160), ("live_effort", "推理等级", 78),
            ("live_calls", "模型调用", 78),
            ("live_ttft", "首响应", 82), ("live_duration", "已用时间", 82),
            ("live_input", "输入", 78), ("live_cached", "缓存", 78),
            ("live_output", "输出", 72), ("live_reasoning", "推理", 72),
            ("live_total", "总 Token", 82), ("live_value", "价值相当于", 90),
            ("live_turn", "Turn ID", 210)
        ], to: consoleTable)
    }

    private func addColumns(_ definitions: [(String, String, CGFloat)], to table: NSTableView) {
        for (id, title, width) in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id.contains("group") || id.contains("model") || id.contains("turn") ? 120 : 58
            table.addTableColumn(column)
        }
    }

    private func rebuildFilterChoices() {
        let previousModel = modelPopup.titleOfSelectedItem
        let previousEffort = effortPopup.titleOfSelectedItem
        let models = Set(allRecords.map(\.model)).sorted()
        let efforts = Set(allRecords.map(\.effort)).sorted()
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: "全部模型")
        modelPopup.addItems(withTitles: models)
        if let previousModel, modelPopup.itemTitles.contains(previousModel) { modelPopup.selectItem(withTitle: previousModel) }
        effortPopup.removeAllItems()
        effortPopup.addItem(withTitle: "全部等级")
        effortPopup.addItems(withTitles: efforts)
        if let previousEffort, effortPopup.itemTitles.contains(previousEffort) { effortPopup.selectItem(withTitle: previousEffort) }
    }

    @objc private func filterChanged() { applyFilters() }

    private func applyFilters() {
        let model = modelPopup.titleOfSelectedItem ?? "全部模型"
        let effort = effortPopup.titleOfSelectedItem ?? "全部等级"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let cutoff: Date?
        switch rangePopup.indexOfSelectedItem {
        case 0: cutoff = today
        case 1: cutoff = calendar.date(byAdding: .day, value: -6, to: today)
        case 2: cutoff = calendar.date(byAdding: .day, value: -29, to: today)
        default: cutoff = nil
        }
        filteredRecords = allRecords.filter { record in
            if model != "全部模型" && record.model != model { return false }
            if effort != "全部等级" && record.effort != effort { return false }
            if let cutoff, let date = metricDate(record.timestamp), date < cutoff { return false }
            return true
        }
        groupRows = grouped(filteredRecords)
        updateSummary()
        chartView.points = dailyPoints(filteredRecords)
        tableView.reloadData()
        let modelCalls = filteredRecords.reduce(0) { $0 + ($1.modelCalls ?? 0) }
        subtitleLabel.stringValue = "\(compactNumber(modelCalls)) 次模型调用 · \(compactNumber(filteredRecords.count)) 个任务 · \(compactNumber(filteredRecords.reduce(0) { $0 + $1.usage.total })) Token"
    }

    private func rebuildConsole() {
        let liveIDs = Set(liveRequests.map(\.turnID))
        let liveRows = liveRequests.map {
            ConsoleRow(isLive: true, turnID: $0.turnID, timestamp: $0.timestamp, model: $0.model,
                       effort: $0.effort, ttftMS: nil, durationMS: elapsedMS(since: $0.timestamp), usage: $0.usage,
                       modelCalls: $0.modelCalls)
        }
        let completedRows = allRecords.filter { !liveIDs.contains($0.turnID) }.map {
            ConsoleRow(isLive: false, turnID: $0.turnID, timestamp: $0.timestamp, model: $0.model,
                       effort: $0.effort, ttftMS: $0.ttftMS, durationMS: $0.durationMS, usage: $0.usage,
                       modelCalls: $0.modelCalls ?? 0)
        }
        consoleRows = Array((liveRows + completedRows).sorted(by: consoleRowIsNewer).prefix(200))
        consoleStatusLabel.stringValue = "每 2 秒刷新 · 进行中 \(liveRows.count) · 显示最近 \(consoleRows.count) 条"
        consoleTable.reloadData()
    }

    private func grouped(_ records: [RequestMetric]) -> [GroupStats] {
        Dictionary(grouping: records) { "\($0.model)\u{1f}\($0.effort)" }.values.map { bucket in
            let first = bucket[0]
            let durations = bucket.map(\.durationMS)
            let ttfts = bucket.map(\.ttftMS).filter { $0 > 0 }
            return GroupStats(
                model: first.model, effort: first.effort,
                modelCalls: bucket.reduce(0) { $0 + ($1.modelCalls ?? 0) },
                input: bucket.reduce(0) { $0 + $1.usage.input },
                cached: bucket.reduce(0) { $0 + $1.usage.cached },
                output: bucket.reduce(0) { $0 + $1.usage.output },
                reasoning: bucket.reduce(0) { $0 + $1.usage.reasoning },
                total: bucket.reduce(0) { $0 + $1.usage.total },
                valueUSD: summedAPICost(bucket),
                typicalTTFT: percentile(ttfts, 0.50), slowerTTFT: percentile(ttfts, 0.95),
                averageDuration: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count
            )
        }.sorted { $0.total > $1.total }
    }

    private func updateSummary() {
        let total = filteredRecords.reduce(0) { $0 + $1.usage.total }
        let input = filteredRecords.reduce(0) { $0 + $1.usage.input }
        let cached = filteredRecords.reduce(0) { $0 + $1.usage.cached }
        let output = filteredRecords.reduce(0) { $0 + $1.usage.output }
        let reasoning = filteredRecords.reduce(0) { $0 + $1.usage.reasoning }
        let ttfts = filteredRecords.map(\.ttftMS).filter { $0 > 0 }
        let durations = filteredRecords.map(\.durationMS)
        let valueUSD = summedAPICost(filteredRecords)
        let modelCalls = filteredRecords.reduce(0) { $0 + ($1.modelCalls ?? 0) }
        let values = [compactNumber(modelCalls), compactNumber(total),
                      formatUSD(valueUSD),
                      formatDuration(percentile(ttfts, 0.50)), formatDuration(percentile(durations, 0.95)),
                      percent(input > 0 ? Double(cached) / Double(input) : 0),
                      percent(output > 0 ? Double(reasoning) / Double(output) : 0)]
        for (label, value) in zip(summaryValues, values) { label.stringValue = value }
    }

    private func dailyPoints(_ records: [RequestMetric]) -> [DailyPoint] {
        let calendar = Calendar.current
        let dated = records.compactMap { record -> (Date, RequestMetric)? in
            metricDate(record.timestamp).map { (calendar.startOfDay(for: $0), record) }
        }
        guard !dated.isEmpty else { return [] }
        let grouped = Dictionary(grouping: dated, by: { $0.0 })
        let latest = dated.map(\.0).max() ?? calendar.startOfDay(for: Date())
        let requestedDays: Int
        switch rangePopup.indexOfSelectedItem {
        case 0: requestedDays = 1
        case 1: requestedDays = 7
        default: requestedDays = 30
        }
        let earliest = calendar.date(byAdding: .day, value: -(requestedDays - 1), to: latest) ?? latest
        var points: [DailyPoint] = []
        var date = earliest
        while date <= latest {
            let rows = grouped[date] ?? []
            points.append(DailyPoint(date: date, tokens: rows.reduce(0) { $0 + $1.1.usage.total },
                                     modelCalls: rows.reduce(0) { $0 + ($1.1.modelCalls ?? 0) }))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? latest.addingTimeInterval(1)
        }
        return points
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === consoleTable ? consoleRows.count : groupRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === consoleTable { return consoleCell(column: tableColumn, row: row) }
        return statsCell(column: tableColumn, row: row)
    }

    private func statsCell(column: NSTableColumn, row: Int) -> NSView? {
        guard row < groupRows.count else { return nil }
        let stats = groupRows[row]
        let id = column.identifier
        let cell = reusableCell(in: tableView, id: id)
        let value: String
        switch id.rawValue {
        case "group": value = "\(stats.model) · \(stats.effort)"
        case "count": value = compactNumber(stats.modelCalls)
        case "total": value = compactNumber(stats.total)
        case "value": value = formatUSD(stats.valueUSD)
        case "input": value = compactNumber(stats.input)
        case "output": value = compactNumber(stats.output)
        case "reasoning": value = compactNumber(stats.reasoning)
        case "typical": value = formatDuration(stats.typicalTTFT)
        case "slower": value = formatDuration(stats.slowerTTFT)
        case "duration": value = formatDuration(stats.averageDuration)
        case "cache": value = percent(stats.cacheRate)
        default: value = ""
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = .left
        switch id.rawValue {
        case "total": cell.toolTip = fullNumber(stats.total) + " Token"
        case "input": cell.toolTip = fullNumber(stats.input) + " Token"
        case "output": cell.toolTip = fullNumber(stats.output) + " Token"
        case "reasoning": cell.toolTip = fullNumber(stats.reasoning) + " Token"
        case "value": cell.toolTip = pricingTooltip(model: stats.model, value: stats.valueUSD)
        default: cell.toolTip = nil
        }
        return cell
    }

    private func consoleCell(column: NSTableColumn, row: Int) -> NSView? {
        guard row < consoleRows.count else { return nil }
        let item = consoleRows[row]
        let id = column.identifier
        let cell = reusableCell(in: consoleTable, id: id)
        let value: String
        switch id.rawValue {
        case "live_status": value = item.isLive ? "● 进行中" : "已完成"
        case "live_time": value = clockLabel(item.timestamp)
        case "live_model": value = item.model
        case "live_effort": value = item.effort
        case "live_calls": value = compactNumber(item.modelCalls)
        case "live_ttft": value = item.ttftMS.map(formatDuration) ?? "--"
        case "live_duration": value = formatDuration(item.durationMS)
        case "live_input": value = compactNumber(item.usage.input)
        case "live_cached": value = compactNumber(item.usage.cached)
        case "live_output": value = compactNumber(item.usage.output)
        case "live_reasoning": value = compactNumber(item.usage.reasoning)
        case "live_total": value = compactNumber(item.usage.total)
        case "live_value": value = formatUSD(estimatedAPICost(model: item.model, usage: item.usage))
        case "live_turn": value = item.turnID
        default: value = ""
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = ["live_calls", "live_input", "live_cached", "live_output", "live_reasoning", "live_total", "live_value"].contains(id.rawValue) ? .right : .left
        cell.textField?.textColor = item.isLive && id.rawValue == "live_status" ? .controlAccentColor : .labelColor
        if id.rawValue == "live_calls" {
            cell.toolTip = fullNumber(item.modelCalls) + " 次模型调用"
        } else if ["live_input", "live_cached", "live_output", "live_reasoning", "live_total"].contains(id.rawValue) {
            let exact: Int = id.rawValue == "live_input" ? item.usage.input : id.rawValue == "live_cached" ? item.usage.cached : id.rawValue == "live_output" ? item.usage.output : id.rawValue == "live_reasoning" ? item.usage.reasoning : item.usage.total
            cell.toolTip = fullNumber(exact) + " Token"
        } else if id.rawValue == "live_value" {
            cell.toolTip = pricingTooltip(model: item.model, value: estimatedAPICost(model: item.model, usage: item.usage))
        } else { cell.toolTip = nil }
        return cell
    }

    private func reusableCell(in table: NSTableView, id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }
}

private final class DailyTokenChartView: NSView {
    var points: [DailyPoint] = [] { didSet { hoveredIndex = nil; tooltipBox.isHidden = true; rebuildSystemToolTips(); needsDisplay = true } }
    private var hoveredIndex: Int?
    private var toolTipIndices: [NSView.ToolTipTag: Int] = [:]
    private let tooltipBox = NSBox()
    private let tooltipLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTooltip()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTooltip()
    }

    private func setupTooltip() {
        tooltipBox.boxType = .custom
        tooltipBox.borderColor = .separatorColor
        tooltipBox.borderWidth = 1
        tooltipBox.cornerRadius = 6
        tooltipBox.fillColor = .windowBackgroundColor
        tooltipBox.isHidden = true
        tooltipLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tooltipLabel.translatesAutoresizingMaskIntoConstraints = false
        tooltipBox.contentView?.addSubview(tooltipLabel)
        if let inner = tooltipBox.contentView {
            NSLayoutConstraint.activate([
                tooltipLabel.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 8),
                tooltipLabel.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -8),
                tooltipLabel.centerYAnchor.constraint(equalTo: inner.centerYAnchor)
            ])
        }
        addSubview(tooltipBox)
        setAccessibilityLabel("每日 Token 柱状图，鼠标悬浮可查看日期、模型调用数和完整 Token 数")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func layout() {
        super.layout()
        rebuildSystemToolTips()
    }

    private func rebuildSystemToolTips() {
        removeAllToolTips()
        toolTipIndices.removeAll()
        guard !points.isEmpty, bounds.width > 0 else { return }
        let plot = plotRect
        let slot = plot.width / CGFloat(points.count)
        for index in points.indices {
            let rect = NSRect(x: plot.minX + CGFloat(index) * slot, y: plot.minY, width: slot, height: plot.height)
            let tag = addToolTip(rect, owner: self, userData: nil)
            toolTipIndices[tag] = index
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = toolTipIndices[tag], points.indices.contains(index) else { return "" }
        let item = points[index]
        return "\(fullDayLabel(item.date)) · \(item.modelCalls) 次模型调用 · \(compactNumber(item.tokens)) Token（\(fullNumber(item.tokens))）"
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        showTooltip(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        showTooltip(at: point)
    }

    private func showTooltip(at point: NSPoint) {
        guard !points.isEmpty else { return }
        let plot = plotRect
        guard plot.contains(point) else { hideTooltip(); return }
        let slot = plot.width / CGFloat(points.count)
        let index = min(max(Int((point.x - plot.minX) / slot), 0), points.count - 1)
        hoveredIndex = index
        let item = points[index]
        tooltipLabel.stringValue = "\(fullDayLabel(item.date)) · \(item.modelCalls) 次模型调用\n\(compactNumber(item.tokens)) Token（\(fullNumber(item.tokens))）"
        let size = NSSize(width: 230, height: 48)
        var x = point.x + 10
        if x + size.width > bounds.maxX { x = point.x - size.width - 10 }
        let y = min(max(point.y + 8, bounds.minY + 4), bounds.maxY - size.height - 4)
        tooltipBox.frame = NSRect(origin: NSPoint(x: max(4, x), y: y), size: size)
        tooltipBox.isHidden = false
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hideTooltip() }

    private func hideTooltip() {
        hoveredIndex = nil
        tooltipBox.isHidden = true
        needsDisplay = true
    }

    private var plotRect: NSRect {
        NSRect(x: bounds.minX + 58, y: bounds.minY + 24,
               width: max(1, bounds.width - 66), height: max(1, bounds.height - 32))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !points.isEmpty else {
            drawText("暂无数据", at: NSPoint(x: 8, y: bounds.midY), color: .secondaryLabelColor)
            return
        }
        let plot = plotRect
        let maxTokens = max(points.map(\.tokens).max() ?? 0, 1)
        let scale = niceTokenScale(maxTokens)
        let slot = plot.width / CGFloat(points.count)
        let barWidth = max(2, min(18, slot * 0.64))
        var tick = 0.0
        while tick <= scale.maximum + scale.step * 0.01 {
            let y = plot.minY + CGFloat(tick / scale.maximum) * plot.height
            NSColor.separatorColor.withAlphaComponent(tick == 0 ? 0.42 : 0.14).setStroke()
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = 1
            grid.stroke()
            drawTextRight(compactNumber(Int(tick.rounded())), rightX: plot.minX - 7, y: y - 6, color: .secondaryLabelColor)
            tick += scale.step
        }
        for (index, point) in points.enumerated() {
            (index == hoveredIndex ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.72)).setFill()
            let height = point.tokens == 0 ? 1 : max(2, CGFloat(Double(point.tokens) / scale.maximum) * plot.height)
            let x = plot.minX + CGFloat(index) * slot + (slot - barWidth) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: plot.minY, width: barWidth, height: height), xRadius: 2, yRadius: 2).fill()
        }
        if let first = points.first, let last = points.last {
            drawText(dayLabel(first.date), at: NSPoint(x: plot.minX, y: 3), color: .secondaryLabelColor)
            let width = (dayLabel(last.date) as NSString).size(withAttributes: textAttributes(.secondaryLabelColor)).width
            drawText(dayLabel(last.date), at: NSPoint(x: plot.maxX - width, y: 3), color: .secondaryLabelColor)
        }
    }

    private func drawText(_ text: String, at point: NSPoint, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: textAttributes(color))
    }

    private func drawTextRight(_ text: String, rightX: CGFloat, y: CGFloat, color: NSColor) {
        let width = (text as NSString).size(withAttributes: textAttributes(color)).width
        drawText(text, at: NSPoint(x: rightX - width, y: y), color: color)
    }

    private func textAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: color]
    }
}

private let statsISOWithFractions: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let statsISO = ISO8601DateFormatter()

private func metricDate(_ value: String) -> Date? { statsISOWithFractions.date(from: value) ?? statsISO.date(from: value) }

private func percentile(_ values: [Int], _ p: Double) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(max(Int(ceil(Double(sorted.count - 1) * p)), 0), sorted.count - 1)]
}

private func formatDuration(_ milliseconds: Int) -> String {
    if milliseconds < 1_000 { return "\(milliseconds)ms" }
    let seconds = Double(milliseconds) / 1_000
    if seconds < 60 { return String(format: seconds >= 10 ? "%.1fs" : "%.2fs", seconds) }
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    if minutes < 60 { return "\(minutes)m \(remainder)s" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

private func elapsedMS(since timestamp: String) -> Int {
    guard let start = metricDate(timestamp) else { return 0 }
    return max(0, Int(Date().timeIntervalSince(start) * 1_000))
}

private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
private func fullNumber(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }

private struct APIPrice {
    let name: String
    let input: Double
    let cached: Double
    let output: Double
}

private func matchesModel(_ model: String, _ base: String) -> Bool {
    model == base || model.hasPrefix(base + "-20")
}

private func apiPrice(for rawModel: String) -> APIPrice? {
    let model = rawModel.lowercased()
    if matchesModel(model, "gpt-5.6-sol") || matchesModel(model, "gpt-5.6") {
        return APIPrice(name: "GPT-5.6 Sol", input: 5, cached: 0.5, output: 30)
    }
    if matchesModel(model, "gpt-5.6-terra") {
        return APIPrice(name: "GPT-5.6 Terra", input: 2.5, cached: 0.25, output: 15)
    }
    if matchesModel(model, "gpt-5.6-luna") {
        return APIPrice(name: "GPT-5.6 Luna", input: 1, cached: 0.1, output: 6)
    }
    if matchesModel(model, "gpt-5.5-pro") {
        return APIPrice(name: "GPT-5.5 Pro", input: 30, cached: 30, output: 180)
    }
    if matchesModel(model, "gpt-5.5") {
        return APIPrice(name: "GPT-5.5", input: 5, cached: 0.5, output: 30)
    }
    if matchesModel(model, "gpt-5.4-pro") {
        return APIPrice(name: "GPT-5.4 Pro", input: 30, cached: 30, output: 180)
    }
    if matchesModel(model, "gpt-5.4") {
        return APIPrice(name: "GPT-5.4", input: 2.5, cached: 0.25, output: 15)
    }
    if matchesModel(model, "gpt-5.3-codex") || model == "codex-auto-review" {
        return APIPrice(name: "GPT-5.3-Codex", input: 1.75, cached: 0.175, output: 14)
    }
    if matchesModel(model, "gpt-5.2-pro") {
        return APIPrice(name: "GPT-5.2 Pro", input: 21, cached: 21, output: 168)
    }
    if matchesModel(model, "gpt-5.2") || matchesModel(model, "gpt-5.2-codex") {
        return APIPrice(name: "GPT-5.2", input: 1.75, cached: 0.175, output: 14)
    }
    if matchesModel(model, "gpt-5-codex") || matchesModel(model, "gpt-5") {
        return APIPrice(name: "GPT-5", input: 1.25, cached: 0.125, output: 10)
    }
    if model == "codex-mini-latest" {
        return APIPrice(name: "codex-mini-latest", input: 1.5, cached: 0.375, output: 6)
    }
    return nil
}

private func estimatedAPICost(model: String, usage: TokenUsage) -> Double? {
    guard let price = apiPrice(for: model) else { return nil }
    let cachedTokens = min(max(usage.cached, 0), max(usage.input, 0))
    let uncachedTokens = max(usage.input - cachedTokens, 0)
    return (Double(uncachedTokens) * price.input
            + Double(cachedTokens) * price.cached
            + Double(max(usage.output, 0)) * price.output) / 1_000_000
}

private func summedAPICost(_ records: [RequestMetric]) -> Double? {
    if records.isEmpty { return 0 }
    let values = records.compactMap { estimatedAPICost(model: $0.model, usage: $0.usage) }
    return values.isEmpty ? nil : values.reduce(0, +)
}

private func formatUSD(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value > 0 && value < 0.01 { return String(format: "≈ $%.4f", value) }
    if value < 1_000 { return String(format: "≈ $%.2f", value) }
    if value < 1_000_000 { return String(format: "≈ $%.2fK", value / 1_000) }
    return String(format: "≈ $%.2fM", value / 1_000_000)
}

private func pricingTooltip(model: String, value: Double?) -> String {
    guard let price = apiPrice(for: model), let value else {
        return "没有可匹配的 OpenAI 官方 API 价格，暂不估算"
    }
    let mapping = model.lowercased() == "codex-auto-review" ? "；codex-auto-review 按 GPT-5.3-Codex 计算" : ""
    return String(format: "%@ 标准 API 价：输入 $%.3g/M · 缓存 $%.3g/M · 输出 $%.3g/M%@\n（总输入 − 缓存输入）× 输入价 + 缓存输入 × 缓存价 + 输出 × 输出价\n估算价值 %@，不代表订阅套餐的实际账单",
                  price.name, price.input, price.cached, price.output, mapping, formatUSD(value))
}

private func niceTokenScale(_ maximum: Int) -> (maximum: Double, step: Double) {
    let rawStep = max(Double(maximum) / 4, 1)
    let magnitude = pow(10, floor(log10(rawStep)))
    let normalized = rawStep / magnitude
    let niceNormalized: Double
    if normalized <= 1 { niceNormalized = 1 }
    else if normalized <= 2 { niceNormalized = 2 }
    else if normalized <= 2.5 { niceNormalized = 2.5 }
    else if normalized <= 5 { niceNormalized = 5 }
    else { niceNormalized = 10 }
    let step = niceNormalized * magnitude
    return (ceil(Double(maximum) / step) * step, step)
}

private func dayLabel(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M/d"
    return formatter.string(from: date)
}

private func fullDayLabel(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
}

private func consoleRowIsNewer(_ lhs: ConsoleRow, _ rhs: ConsoleRow) -> Bool {
    switch (metricDate(lhs.timestamp), metricDate(rhs.timestamp)) {
    case let (left?, right?):
        if left != right { return left > right }
    case (_?, nil): return true
    case (nil, _?): return false
    case (nil, nil): break
    }
    return lhs.timestamp > rhs.timestamp
}

private func clockLabel(_ timestamp: String) -> String {
    guard let date = metricDate(timestamp) else { return "--" }
    let calendar = Calendar.current
    let now = Date()
    let format: String
    if calendar.isDate(date, inSameDayAs: now) {
        format = "HH:mm:ss"
    } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        format = "MM-dd HH:mm:ss"
    } else {
        format = "yyyy-MM-dd HH:mm:ss"
    }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = format
    return formatter.string(from: date)
}
