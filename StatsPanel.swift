import AppKit
import Foundation

private struct GroupStats {
    let model: String
    let effort: String
    let modelCalls: Int
    let activeCalls: Int
    let completedTurns: Int
    let input: Int
    let cached: Int
    let output: Int
    let reasoning: Int
    let total: Int
    let cost: APICostSummary
    let typicalTTFT: Int
    let slowerTTFT: Int
    let averageDuration: Int
    let tokenRate: Double?

    var cacheRate: Double { input > 0 ? Double(cached) / Double(input) : 0 }
}

private struct DailyPoint {
    let date: Date
    let tokens: Int
    let modelCalls: Int
}

private struct ConsoleRow: Equatable {
    let id: String
    let status: String?
    let sessionName: String
    let timestamp: String
    let model: String
    let responseModel: String?
    let effort: String
    let serviceTier: String?
    let ttftMS: Int?
    let ttftEstimated: Bool?
    let durationMS: Int?
    let durationEstimated: Bool?
    let operation: String?
    let tokenRate: Double?
    let usage: TokenUsage?

    var hasModelMismatch: Bool {
        guard let responseModel else { return false }
        return normalizedModelName(model) != normalizedModelName(responseModel)
    }
}

private enum MetricCardStyle {
    case primary
    case secondary
}

private enum StatsDateRange: Int {
    case today
    case yesterday
    case dayBeforeYesterday
    case last7Days
    case last30Days
    case allTime
    case custom
}

private struct StatsDateBounds {
    let start: Date?
    let end: Date?
    let includesEnd: Bool
}

private struct OverviewData {
    let models: [String]
    let efforts: [String]
    let groups: [GroupStats]
    let chart: [DailyPoint]
    let summary: [String]
    let subtitle: String
    let completedCalls: Int
    let activeCalls: Int
}

private struct OverviewSignature: Equatable {
    struct ActiveKey: Equatable {
        let id: String
        let model: String
        let effort: String
    }
    let recordCount: Int
    let callCount: Int
    let dayStart: Date
    let live: [LiveRequest]
    let active: [ActiveKey]
}

private struct ModelEffortKey: Hashable {
    let model: String
    let effort: String
}

final class StatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    private var allRecords: [RequestMetric] = []
    private var liveRequests: [LiveRequest] = []
    private var apiCalls: [APICallMetric] = []
    private var activeAPICalls: [ActiveAPICall] = []
    private var compactionCount = 0
    private var sessionTitles: [String: String] = [:]
    private var groupRows: [GroupStats] = []
    private var consoleRows: [ConsoleRow] = []

    private let rangePopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let effortPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let consoleTable = NSTableView()
    private let chartView = DailyTokenChartView()
    private let chartTitleLabel = NSTextField(labelWithString: "每日 Token 趋势")
    private let tabs = NSTabView()
    private var summaryValues: [NSTextField] = []
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let consoleStatusLabel = NSTextField(labelWithString: "")
    private var chartHeightConstraint: NSLayoutConstraint?
    private let consolePageLabel = NSTextField(labelWithString: "")
    private lazy var previousPageButton = ClickableButton(title: "‹ 上一页", target: self, action: #selector(previousConsolePage))
    private lazy var nextPageButton = ClickableButton(title: "下一页 ›", target: self, action: #selector(nextConsolePage))
    private let consolePageSize = 100
    private var consolePage = 0
    private var customDateBounds: StatsDateBounds?
    private var lastAppliedRangeIndex = StatsDateRange.today.rawValue
    private let overviewQueue = DispatchQueue(label: "com.codexpulse.stats-overview", qos: .userInitiated)
    private var overviewGeneration = 0
    private var overviewInFlight = false
    private var overviewPending = false
    private var readyOverview: OverviewData?
    private var readyOverviewGeneration = -1
    private var appliedOverviewGeneration = -1
    private var lastOverviewSignature: OverviewSignature?
    private var consoleNeedsRefresh = true

    var isLiveConsoleVisible: Bool {
        window?.isVisible == true && (tabs.selectedTabViewItem?.identifier as? String) == "console"
    }

    init(snapshot: StatsDataSnapshot) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Pulse"
        window.minSize = NSSize(width: 1040, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        update(snapshot: snapshot)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(snapshot: StatsDataSnapshot) {
        allRecords = snapshot.records
        liveRequests = snapshot.liveRequests
        apiCalls = snapshot.apiCalls
        activeAPICalls = snapshot.activeAPICalls
        compactionCount = snapshot.compactionCount
        sessionTitles = snapshot.sessionTitles
        let signature = OverviewSignature(recordCount: allRecords.count, callCount: apiCalls.count,
                                          dayStart: snapshot.dayStart,
                                          live: liveRequests,
                                          active: activeAPICalls.map {
                                              OverviewSignature.ActiveKey(id: $0.id, model: $0.model, effort: $0.effort)
                                          })
        if signature != lastOverviewSignature {
            lastOverviewSignature = signature
            requestOverviewRefresh()
        }
        consoleNeedsRefresh = true
        if isLiveConsoleVisible { rebuildConsole() }
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
        tabs.delegate = self
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        switch tabViewItem?.identifier as? String {
        case "overview":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, (self.tabs.selectedTabViewItem?.identifier as? String) == "overview",
                      let ready = self.readyOverview,
                      self.readyOverviewGeneration == self.overviewGeneration else { return }
                self.applyOverview(ready, generation: self.readyOverviewGeneration)
            }
        case "console":
            // Let AppKit paint the selected tab before refreshing its table.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.consoleNeedsRefresh,
                      (self.tabs.selectedTabViewItem?.identifier as? String) == "console" else { return }
                self.rebuildConsole(animated: false)
            }
        default:
            break
        }
    }

    private func buildOverview(in content: NSView) {
        let title = NSTextField(labelWithString: "请求概览")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        rangePopup.addItems(withTitles: ["今日", "昨天", "前天", "最近 7 天", "最近 30 天", "全部时间", "自选范围…"])
        rangePopup.selectItem(at: 0)
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged)
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

        let calls = metricBox("API 请求", help: "每次产生非零 last_token_usage 的底层模型 API 调用", style: .primary)
        let total = metricBox("总 Token", help: nil, style: .primary, highlighted: true)
        let value = metricBox("价值相当于", help: "逐次按模型、服务档位和长上下文 API 单价估算；未公布价格的调用不计入已知部分，不代表实际账单", style: .primary, highlighted: true)
        let typical = metricBox("典型首响应", help: "一半请求的首响应时间不超过这个值", style: .secondary)
        let slower = metricBox("P95 总耗时", help: "95% 的请求总耗时不超过这个值", style: .secondary)
        let tokenRate = metricBox("Token 速率", help: "已完成调用的输出 Token ÷ 出字阶段耗时；不可靠的本地事件时序不参与计算", style: .secondary)
        let cache = metricBox("缓存命中率", help: "输入 Token 中由缓存直接复用的比例", style: .secondary)
        let reasoning = metricBox("推理占比", help: "输出 Token 中用于模型推理的比例", style: .secondary)
        summaryValues = [calls.1, total.1, value.1, typical.1, slower.1, tokenRate.1, cache.1, reasoning.1]

        let primaryCards = [total.0, value.0, calls.0]
        let primaryGrid = NSGridView(views: [primaryCards])
        primaryGrid.columnSpacing = 10
        for index in primaryCards.indices { primaryGrid.column(at: index).xPlacement = .fill }
        for card in primaryCards.dropFirst() { card.widthAnchor.constraint(equalTo: primaryCards[0].widthAnchor).isActive = true }

        let secondaryCards = [typical.0, slower.0, tokenRate.0, cache.0, reasoning.0]
        let secondaryGrid = NSGridView(views: [secondaryCards])
        secondaryGrid.columnSpacing = 8
        for index in secondaryCards.indices { secondaryGrid.column(at: index).xPlacement = .fill }
        for card in secondaryCards.dropFirst() { card.widthAnchor.constraint(equalTo: secondaryCards[0].widthAnchor).isActive = true }

        let summaryStack = NSStackView(views: [primaryGrid, secondaryGrid])
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 8
        primaryGrid.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true
        secondaryGrid.widthAnchor.constraint(equalTo: summaryStack.widthAnchor).isActive = true

        chartTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let chartHint = NSTextField(labelWithString: "悬浮查看明细")
        chartHint.font = .systemFont(ofSize: 10)
        chartHint.textColor = .tertiaryLabelColor
        let chartHeader = NSStackView(views: [chartTitleLabel, NSView(), chartHint])
        chartHeader.orientation = .horizontal
        chartHeader.alignment = .centerY
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartHeightConstraint = chartView.heightAnchor.constraint(equalToConstant: 96)
        chartHeightConstraint?.isActive = true

        let tableTitle = sectionTitle("模型与推理等级")
        let termHelp = NSTextField(labelWithString: "典型 = P50 · 较慢 = P95")
        termHelp.font = .systemFont(ofSize: 10)
        termHelp.textColor = .tertiaryLabelColor
        let tableHeader = NSStackView(views: [tableTitle, NSView(), termHelp])
        tableHeader.orientation = .horizontal
        tableHeader.alignment = .centerY

        configureStatsTable()
        let scroll = makeScrollView(for: tableView)
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 235).isActive = true

        let stack = NSStackView(views: [header, summaryStack, chartHeader, chartView, tableHeader, scroll])
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
            summaryStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            tableHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func buildConsole(in content: NSView) {
        let title = NSTextField(labelWithString: "实时 API 请求")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        consoleStatusLabel.font = .systemFont(ofSize: 12)
        consoleStatusLabel.textColor = .secondaryLabelColor
        consolePageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        consolePageLabel.textColor = .secondaryLabelColor
        previousPageButton.controlSize = .small
        nextPageButton.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pager = NSStackView(views: [previousPageButton, consolePageLabel, nextPageButton])
        pager.orientation = .horizontal
        pager.alignment = .centerY
        pager.spacing = 8
        let statusRow = NSStackView(views: [consoleStatusLabel, spacer, pager])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        let header = NSStackView(views: [title, statusRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        configureConsoleTable()
        let scroll = makeScrollView(for: consoleTable)

        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: header.widthAnchor),
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

    private func metricBox(_ title: String, help: String?, style: MetricCardStyle, highlighted: Bool = false) -> (NSBox, NSTextField) {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.34) : NSColor.separatorColor.withAlphaComponent(0.34)
        box.borderWidth = style == .primary ? 1 : 0
        box.cornerRadius = style == .primary ? 10 : 8
        box.fillColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.09) : NSColor.controlBackgroundColor.withAlphaComponent(style == .primary ? 0.88 : 0.55)
        box.toolTip = help
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: style == .primary ? 82 : 56).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: style == .primary ? 11 : 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        let value = NSTextField(labelWithString: "--")
        value.font = .monospacedDigitSystemFont(ofSize: style == .primary ? 28 : 18, weight: style == .primary ? .semibold : .medium)
        value.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = style == .primary ? 6 : 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let inner = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: style == .primary ? 14 : 12),
                stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: style == .primary ? -14 : -12),
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
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.45)
        tableView.rowHeight = 30
        addColumns([
            ("group", "模型 / 推理等级", 185), ("count", "API 请求", 78),
            ("total", "总 Token", 82), ("value", "价值相当于", 90), ("input", "输入", 78),
            ("output", "输出", 70), ("reasoning", "推理", 70),
            ("rate", "Token 速率", 86),
            ("typical", "典型首响应", 92), ("slower", "较慢首响应", 92),
            ("duration", "平均耗时", 82), ("cache", "缓存命中", 78)
        ], to: tableView)
    }

    private func configureConsoleTable() {
        consoleTable.delegate = self
        consoleTable.dataSource = self
        consoleTable.columnAutoresizingStyle = .noColumnAutoresizing
        consoleTable.usesAlternatingRowBackgroundColors = false
        consoleTable.gridStyleMask = [.solidHorizontalGridLineMask]
        consoleTable.gridColor = NSColor.separatorColor.withAlphaComponent(0.22)
        consoleTable.rowHeight = 58
        addColumns([
            ("api_event", "事件", 122), ("api_session", "会话", 164),
            ("api_model", "模型配置", 226), ("api_performance", "响应表现", 188),
            ("api_usage", "Token 用量", 250), ("api_value", "价值", 96)
        ], to: consoleTable)
    }

    private func addColumns(_ definitions: [(String, String, CGFloat)], to table: NSTableView) {
        for (id, title, width) in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id.contains("group") || id.contains("model") || id.contains("session") ? 100 : 52
            table.addTableColumn(column)
        }
    }

    private func rebuildFilterChoices(models: [String], efforts: [String]) {
        let modelTitles = ["全部模型"] + models
        let effortTitles = ["全部等级"] + efforts
        guard modelPopup.itemTitles != modelTitles || effortPopup.itemTitles != effortTitles else { return }
        let previousModel = modelPopup.titleOfSelectedItem
        let previousEffort = effortPopup.titleOfSelectedItem
        if modelPopup.itemTitles != modelTitles {
            modelPopup.removeAllItems()
            modelPopup.addItems(withTitles: modelTitles)
            if let previousModel, modelPopup.itemTitles.contains(previousModel) {
                modelPopup.selectItem(withTitle: previousModel)
            }
        }
        if effortPopup.itemTitles != effortTitles {
            effortPopup.removeAllItems()
            effortPopup.addItems(withTitles: effortTitles)
            if let previousEffort, effortPopup.itemTitles.contains(previousEffort) {
                effortPopup.selectItem(withTitle: previousEffort)
            }
        }
        if previousModel != nil && modelPopup.titleOfSelectedItem != previousModel
            || previousEffort != nil && effortPopup.titleOfSelectedItem != previousEffort {
            requestOverviewRefresh()
        }
    }

    @objc private func filterChanged() { requestOverviewRefresh() }

    @objc private func rangeChanged() {
        guard rangePopup.indexOfSelectedItem == StatsDateRange.custom.rawValue else {
            lastAppliedRangeIndex = rangePopup.indexOfSelectedItem
            rangePopup.toolTip = nil
            requestOverviewRefresh()
            return
        }
        presentCustomRangePicker()
    }

    private func presentCustomRangePicker() {
        let calendar = Calendar.current
        let initialStart = customDateBounds?.start ?? calendar.startOfDay(for: Date())
        let initialEnd = customDateBounds?.end ?? Date()
        let startPicker = dateTimePicker(initialStart)
        let endPicker = dateTimePicker(initialEnd)
        let fields = NSStackView(views: [labeledControl("开始时间", startPicker), labeledControl("结束时间", endPicker)])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 92))
        accessory.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            fields.topAnchor.constraint(equalTo: accessory.topAnchor),
            fields.bottomAnchor.constraint(equalTo: accessory.bottomAnchor)
        ])

        let alert = NSAlert()
        alert.messageText = "选择统计时间范围"
        alert.informativeText = "开始和结束时间均按当前系统时区计算。"
        alert.accessoryView = accessory
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            rangePopup.selectItem(at: lastAppliedRangeIndex)
            return
        }
        guard startPicker.dateValue <= endPicker.dateValue else {
            rangePopup.selectItem(at: lastAppliedRangeIndex)
            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = "时间范围无效"
            error.informativeText = "开始时间不能晚于结束时间。"
            error.runModal()
            return
        }
        customDateBounds = StatsDateBounds(start: startPicker.dateValue, end: endPicker.dateValue, includesEnd: true)
        lastAppliedRangeIndex = StatsDateRange.custom.rawValue
        rangePopup.item(at: StatsDateRange.custom.rawValue)?.title = customRangeTitle(start: startPicker.dateValue, end: endPicker.dateValue)
        rangePopup.toolTip = "自选范围：\(fullDateTime(startPicker.dateValue)) 至 \(fullDateTime(endPicker.dateValue))"
        rangePopup.selectItem(at: StatsDateRange.custom.rawValue)
        requestOverviewRefresh()
    }

    private func dateTimePicker(_ date: Date) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.locale = Locale(identifier: "zh_CN")
        picker.timeZone = .current
        picker.dateValue = date
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return picker
    }

    private func customRangeTitle(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M/d HH:mm"
        return "自选 \(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private func fullDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func selectedDateBounds() -> StatsDateBounds {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? Date.distantFuture
        switch StatsDateRange(rawValue: rangePopup.indexOfSelectedItem) ?? .today {
        case .today:
            return StatsDateBounds(start: today, end: tomorrow, includesEnd: false)
        case .yesterday:
            return StatsDateBounds(start: calendar.date(byAdding: .day, value: -1, to: today), end: today, includesEnd: false)
        case .dayBeforeYesterday:
            return StatsDateBounds(start: calendar.date(byAdding: .day, value: -2, to: today),
                                   end: calendar.date(byAdding: .day, value: -1, to: today), includesEnd: false)
        case .last7Days:
            return StatsDateBounds(start: calendar.date(byAdding: .day, value: -6, to: today), end: tomorrow, includesEnd: false)
        case .last30Days:
            return StatsDateBounds(start: calendar.date(byAdding: .day, value: -29, to: today), end: tomorrow, includesEnd: false)
        case .allTime:
            return StatsDateBounds(start: nil, end: nil, includesEnd: false)
        case .custom:
            return customDateBounds ?? StatsDateBounds(start: today, end: Date(), includesEnd: true)
        }
    }

    private func requestOverviewRefresh() {
        overviewGeneration &+= 1
        overviewPending = true
        startOverviewRefreshIfNeeded()
    }

    private func startOverviewRefreshIfNeeded() {
        guard overviewPending, !overviewInFlight else { return }
        overviewPending = false
        overviewInFlight = true
        let generation = overviewGeneration
        let records = allRecords
        let live = liveRequests
        let calls = apiCalls
        let active = activeAPICalls
        let model = modelPopup.titleOfSelectedItem ?? "全部模型"
        let effort = effortPopup.titleOfSelectedItem ?? "全部等级"
        let range = StatsDateRange(rawValue: rangePopup.indexOfSelectedItem) ?? .today
        let bounds = selectedDateBounds()
        overviewQueue.async { [weak self] in
            let result = Self.buildOverview(records: records, live: live, calls: calls, active: active,
                                            model: model, effort: effort, range: range, bounds: bounds)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.overviewInFlight = false
                if generation == self.overviewGeneration {
                    self.readyOverview = result
                    self.readyOverviewGeneration = generation
                    if (self.tabs.selectedTabViewItem?.identifier as? String) == "overview" {
                        self.applyOverview(result, generation: generation)
                    }
                }
                self.startOverviewRefreshIfNeeded()
            }
        }
    }

    private func applyOverview(_ result: OverviewData, generation: Int) {
        guard appliedOverviewGeneration != generation else { return }
        appliedOverviewGeneration = generation
        rebuildFilterChoices(models: result.models, efforts: result.efforts)
        groupRows = result.groups
        for (label, value) in zip(summaryValues, result.summary) { label.stringValue = value }
        summaryValues.first?.toolTip = "\(result.completedCalls) 次已完成 · \(result.activeCalls) 次进行中"
        summaryValues.dropFirst().first?.toolTip = "包含进行中会话已上报的 Token；尚未上报的用量不作推测"
        summaryValues[2].toolTip = "只估算已完成且有完整用量的 API 调用；进行中的调用尚无最终价格"
        subtitleLabel.stringValue = result.subtitle
        chartView.points = result.chart
        tableView.reloadData()
        switch StatsDateRange(rawValue: rangePopup.indexOfSelectedItem) ?? .today {
        case .today:
            chartTitleLabel.stringValue = "今日 Token"
            chartHeightConstraint?.constant = 96
        case .yesterday:
            chartTitleLabel.stringValue = "昨天 Token"
            chartHeightConstraint?.constant = 96
        case .dayBeforeYesterday:
            chartTitleLabel.stringValue = "前天 Token"
            chartHeightConstraint?.constant = 96
        case .custom:
            chartTitleLabel.stringValue = "自选范围 Token 趋势"
            chartHeightConstraint?.constant = 128
        case .last7Days, .last30Days, .allTime:
            chartTitleLabel.stringValue = "每日 Token 趋势"
            chartHeightConstraint?.constant = 128
        }
    }

    private func rebuildConsole(animated: Bool = true) {
        consoleNeedsRefresh = false
        let totalCount = apiCalls.count + activeAPICalls.count
        let pageCount = max(1, Int(ceil(Double(totalCount) / Double(consolePageSize))))
        consolePage = min(consolePage, pageCount - 1)
        let newRows = consoleRowsForCurrentPage()
        applyConsoleRows(newRows, animated: animated && consolePage == 0)
        let activeSuffix = activeAPICalls.isEmpty ? "" : " · \(activeAPICalls.count) 进行中"
        let compactionSuffix = compactionCount > 0 ? " · \(fullNumber(compactionCount)) 次压缩" : ""
        consoleStatusLabel.stringValue = "\(fullNumber(apiCalls.count)) 次 API 请求\(activeSuffix)\(compactionSuffix)"
        consolePageLabel.stringValue = "\(consolePage + 1) / \(pageCount)"
        previousPageButton.isEnabled = consolePage > 0
        nextPageButton.isEnabled = consolePage + 1 < pageCount
    }

    private func consoleRowsForCurrentPage() -> [ConsoleRow] {
        let start = consolePage * consolePageSize
        let end = min(start + consolePageSize, apiCalls.count + activeAPICalls.count)
        guard start < end else { return [] }
        var rows: [ConsoleRow] = []
        rows.reserveCapacity(end - start)
        let activeStart = min(start, activeAPICalls.count)
        let activeEnd = min(end, activeAPICalls.count)
        if activeStart < activeEnd {
            for index in activeStart..<activeEnd {
                let call = activeAPICalls[index]
                rows.append(ConsoleRow(id: call.id, status: call.status,
                                       sessionName: sessionTitles[call.sessionID] ?? call.sessionID,
                                       timestamp: call.timestamp, model: call.model,
                                       responseModel: call.responseModel,
                                       effort: call.effort, serviceTier: call.serviceTier,
                                       ttftMS: call.ttftMS, ttftEstimated: call.ttftEstimated,
                                       durationMS: call.durationMS, durationEstimated: call.durationEstimated,
                                       operation: nil, tokenRate: nil, usage: nil))
            }
        }
        let completedStart = max(0, start - activeAPICalls.count)
        let completedEnd = min(apiCalls.count, end - activeAPICalls.count)
        if completedStart < completedEnd {
            for index in completedStart..<completedEnd {
                let call = apiCalls[index]
                rows.append(ConsoleRow(id: call.id, status: nil,
                                       sessionName: sessionTitles[call.sessionID] ?? call.sessionID,
                                       timestamp: call.timestamp, model: call.model,
                                       responseModel: call.responseModel,
                                       effort: call.effort, serviceTier: call.serviceTier,
                                       ttftMS: call.ttftMS, ttftEstimated: call.ttftEstimated,
                                       durationMS: call.durationMS, durationEstimated: call.durationEstimated,
                                       operation: call.operation, tokenRate: tokenRate(for: call),
                                       usage: call.usage))
            }
        }
        return rows
    }

    private func applyConsoleRows(_ newRows: [ConsoleRow], animated: Bool) {
        let oldRows = consoleRows
        guard animated, !oldRows.isEmpty else {
            consoleRows = newRows
            consoleTable.reloadData()
            return
        }
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        let oldSet = Set(oldIDs)
        let newSet = Set(newIDs)
        guard oldSet.count == oldIDs.count,
              newSet.count == newIDs.count,
              oldIDs.filter(newSet.contains) == newIDs.filter(oldSet.contains) else {
            consoleRows = newRows
            consoleTable.reloadData()
            return
        }
        let removals = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
        let insertions = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
        var oldByID: [String: ConsoleRow] = [:]
        for row in oldRows { oldByID[row.id] = row }
        let contentChanges = IndexSet(newRows.indices.filter {
            guard let old = oldByID[newRows[$0].id] else { return false }
            return old != newRows[$0]
        })
        let heightChanges = IndexSet(newRows.indices.filter {
            guard let old = oldByID[newRows[$0].id] else { return false }
            return old.hasModelMismatch != newRows[$0].hasModelMismatch
        })
        consoleRows = newRows
        if !removals.isEmpty || !insertions.isEmpty {
            consoleTable.beginUpdates()
            consoleTable.removeRows(at: removals, withAnimation: [])
            consoleTable.insertRows(at: insertions, withAnimation: [.slideDown, .effectFade])
            consoleTable.endUpdates()
        }
        if !heightChanges.isEmpty {
            consoleTable.noteHeightOfRows(withIndexesChanged: heightChanges)
        }
        if !contentChanges.isEmpty {
            consoleTable.reloadData(forRowIndexes: contentChanges,
                                    columnIndexes: IndexSet(integersIn: 0..<consoleTable.numberOfColumns))
        }
    }

    @objc private func previousConsolePage() {
        guard consolePage > 0 else { return }
        consolePage -= 1
        rebuildConsole(animated: false)
    }

    @objc private func nextConsolePage() {
        let pageCount = max(1, Int(ceil(Double(apiCalls.count + activeAPICalls.count) / Double(consolePageSize))))
        guard consolePage + 1 < pageCount else { return }
        consolePage += 1
        rebuildConsole(animated: false)
    }

    // Pure aggregation runs on overviewQueue; only the small result is applied on the main thread.
    private static func buildOverview(records: [RequestMetric], live: [LiveRequest],
                                      calls: [APICallMetric], active: [ActiveAPICall],
                                      model: String, effort: String, range: StatsDateRange,
                                      bounds: StatsDateBounds) -> OverviewData {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let utc = ISO8601DateFormatter()
        let startKey = bounds.start.map { String(utc.string(from: $0).prefix(19)) }
        let endKey = bounds.end.map { String(utc.string(from: $0).prefix(19)) }
        func parseDate(_ value: String) -> Date? { fractional.date(from: value) ?? plain.date(from: value) }
        func matches(_ candidateModel: String, _ candidateEffort: String, _ timestamp: String) -> Bool {
            if model != "全部模型" && candidateModel != model { return false }
            if effort != "全部等级" && candidateEffort != effort { return false }
            guard bounds.start != nil || bounds.end != nil else { return true }
            // Codex emits UTC ISO timestamps. Reject most out-of-range history by
            // sortable second before invoking the comparatively expensive parser.
            if timestamp.hasSuffix("Z"), timestamp.count >= 20 {
                let key = String(timestamp.prefix(19))
                if let startKey, key < startKey { return false }
                if let endKey, key > endKey { return false }
                if key != startKey && key != endKey { return true }
            }
            guard let date = parseDate(timestamp) else { return false }
            if let start = bounds.start, date < start { return false }
            if let end = bounds.end, bounds.includesEnd ? date > end : date >= end { return false }
            return true
        }
        let models = Set(records.map(\.model) + live.map(\.model) + calls.map(\.model) + active.map(\.model)).sorted()
        let efforts = Set(records.map(\.effort) + live.map(\.effort) + calls.map(\.effort) + active.map(\.effort)).sorted()
        let filteredRecords = records.filter { matches($0.model, $0.effort, $0.timestamp) }
        let filteredLive = live.filter { matches($0.model, $0.effort, $0.timestamp) }
        let filteredCalls = calls.filter { matches($0.model, $0.effort, $0.timestamp) }
        let filteredActive = active.filter { matches($0.model, $0.effort, $0.timestamp) }
        let groups = grouped(records: filteredRecords, live: filteredLive,
                             calls: filteredCalls, active: filteredActive)

        let usage = (filteredRecords.map(\.usage) + filteredLive.map(\.usage)).reduce(into: TokenUsage()) { sum, item in
            sum.input += item.input
            sum.cached += item.cached
            sum.output += item.output
            sum.reasoning += item.reasoning
            sum.total += item.total
        }
        let ttfts = filteredRecords.map(\.ttftMS).filter { $0 > 0 }
        let durations = filteredRecords.map(\.durationMS)
        let completedCalls = filteredRecords.reduce(0) { $0 + ($1.modelCalls ?? 0) }
            + filteredLive.reduce(0) { $0 + $1.modelCalls }
        let activeCalls = filteredActive.count
        let compactions = filteredCalls.reduce(0) { $0 + ($1.operation == "compaction" ? 1 : 0) }
        let cost = summedAPICost(filteredCalls)
        let costLabel = filteredCalls.isEmpty && activeCalls > 0 ? "待完成" : formatAPICost(cost)
        let activeSuffix = filteredLive.isEmpty ? "" : "（\(compactNumber(filteredLive.count)) 进行中）"
        let callSuffix = activeCalls == 0 ? "" : " · \(compactNumber(activeCalls)) 进行中"
        let compactionSuffix = compactions == 0 ? "" : " · \(compactNumber(compactions)) 次压缩"
        return OverviewData(
            models: models, efforts: efforts, groups: groups,
            chart: dailyPoints(records: filteredRecords, live: filteredLive, active: filteredActive,
                               range: range, bounds: bounds, parseDate: parseDate),
            summary: [compactNumber(completedCalls + activeCalls), compactNumber(usage.total),
                      costLabel,
                      ttfts.isEmpty ? "--" : formatDuration(percentile(ttfts, 0.50)),
                      durations.isEmpty ? "--" : formatDuration(percentile(durations, 0.95)),
                      formatTokenRate(aggregateTokenRate(filteredCalls)),
                      percent(usage.input > 0 ? Double(usage.cached) / Double(usage.input) : 0),
                      percent(usage.output > 0 ? Double(usage.reasoning) / Double(usage.output) : 0)],
            subtitle: "\(compactNumber(filteredRecords.count + filteredLive.count)) 个任务\(activeSuffix) · \(compactNumber(completedCalls)) 次已完成 API 请求\(callSuffix)\(compactionSuffix)",
            completedCalls: completedCalls, activeCalls: activeCalls
        )
    }

    private static func grouped(records: [RequestMetric], live: [LiveRequest],
                                calls: [APICallMetric], active: [ActiveAPICall]) -> [GroupStats] {
        let recordsByGroup = Dictionary(grouping: records) { ModelEffortKey(model: $0.model, effort: $0.effort) }
        let liveByGroup = Dictionary(grouping: live) { ModelEffortKey(model: $0.model, effort: $0.effort) }
        let callsByGroup = Dictionary(grouping: calls) { ModelEffortKey(model: $0.model, effort: $0.effort) }
        let activeByGroup = Dictionary(grouping: active) { ModelEffortKey(model: $0.model, effort: $0.effort) }
        let keys = Set(recordsByGroup.keys).union(liveByGroup.keys).union(callsByGroup.keys).union(activeByGroup.keys)
        return keys.map { groupKey in
            let finished = recordsByGroup[groupKey] ?? []
            let ongoing = liveByGroup[groupKey] ?? []
            let completedAPI = callsByGroup[groupKey] ?? []
            let activeAPI = activeByGroup[groupKey] ?? []
            let usage = (finished.map(\.usage) + ongoing.map(\.usage)).reduce(into: TokenUsage()) { sum, item in
                sum.input += item.input
                sum.cached += item.cached
                sum.output += item.output
                sum.reasoning += item.reasoning
                sum.total += item.total
            }
            let durations = finished.map(\.durationMS)
            let ttfts = finished.map(\.ttftMS).filter { $0 > 0 }
            return GroupStats(
                model: groupKey.model, effort: groupKey.effort,
                modelCalls: finished.reduce(0) { $0 + ($1.modelCalls ?? 0) }
                    + ongoing.reduce(0) { $0 + $1.modelCalls } + activeAPI.count,
                activeCalls: activeAPI.count,
                completedTurns: finished.count,
                input: usage.input, cached: usage.cached, output: usage.output,
                reasoning: usage.reasoning, total: usage.total,
                cost: summedAPICost(completedAPI),
                typicalTTFT: percentile(ttfts, 0.50), slowerTTFT: percentile(ttfts, 0.95),
                averageDuration: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count,
                tokenRate: aggregateTokenRate(completedAPI)
            )
        }.sorted { $0.total > $1.total }
    }

    private static func dailyPoints(records: [RequestMetric], live: [LiveRequest],
                                    active: [ActiveAPICall], range: StatsDateRange,
                                    bounds: StatsDateBounds, parseDate: (String) -> Date?) -> [DailyPoint] {
        let calendar = Calendar.current
        var byDay: [Date: (tokens: Int, modelCalls: Int)] = [:]
        func add(_ timestamp: String, tokens: Int, calls: Int) {
            guard let date = parseDate(timestamp) else { return }
            let day = calendar.startOfDay(for: date)
            var totals = byDay[day] ?? (tokens: 0, modelCalls: 0)
            totals.tokens += tokens
            totals.modelCalls += calls
            byDay[day] = totals
        }
        for record in records { add(record.timestamp, tokens: record.usage.total, calls: record.modelCalls ?? 0) }
        for request in live { add(request.timestamp, tokens: request.usage.total, calls: request.modelCalls) }
        for call in active { add(call.timestamp, tokens: 0, calls: 1) }
        let earliest: Date
        let latest: Date
        if range == .allTime {
            guard let latestDay = byDay.keys.max() else { return [] }
            latest = latestDay
            earliest = calendar.date(byAdding: .day, value: -29, to: latest) ?? latest
        } else {
            guard let start = bounds.start, let end = bounds.end else { return [] }
            earliest = calendar.startOfDay(for: start)
            let inclusiveEnd = bounds.includesEnd ? end : end.addingTimeInterval(-1)
            latest = calendar.startOfDay(for: max(start, inclusiveEnd))
        }
        var points: [DailyPoint] = []
        var date = earliest
        while date <= latest {
            let totals = byDay[date] ?? (tokens: 0, modelCalls: 0)
            points.append(DailyPoint(date: date, tokens: totals.tokens, modelCalls: totals.modelCalls))
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? latest.addingTimeInterval(1)
        }
        return points
    }

#if PRICING_TESTS
    static func runOverviewRegressionTests() {
        let timestamp = "2026-09-23T08:00:00Z"
        let finishedUsage = TokenUsage(input: 100, cached: 20, output: 10, reasoning: 4, total: 110)
        let liveUsage = TokenUsage(input: 40, cached: 20, output: 10, reasoning: 2, total: 50)
        let finished = RequestMetric(turnID: "finished", timestamp: timestamp, model: "gpt-6-sol",
                                     effort: "high", ttftMS: 500, durationMS: 2_000,
                                     usage: finishedUsage, modelCalls: 1, source: "test")
        let live = LiveRequest(turnID: "live", timestamp: timestamp, model: "gpt-6-sol",
                               effort: "high", usage: liveUsage, modelCalls: 1, source: "test")
        let completedAPI = APICallMetric(id: "finished-api", sessionID: "session", turnID: "finished",
                                         timestamp: timestamp, model: "gpt-6-sol", responseModel: nil,
                                         effort: "high", serviceTier: "default", ttftMS: 500,
                                         ttftEstimated: false, durationMS: 2_000, durationEstimated: false,
                                         operation: nil, usage: finishedUsage, source: "test")
        let activeAPI = ActiveAPICall(id: "active-api", sessionID: "session", turnID: "live",
                                      timestamp: timestamp, model: "gpt-6-sol", responseModel: nil,
                                      effort: "high", serviceTier: "default", ttftMS: nil,
                                      ttftEstimated: nil, durationMS: nil, durationEstimated: nil,
                                      status: "请求中", source: "test")
        let bounds = StatsDateBounds(start: nil, end: nil, includesEnd: false)
        let running = buildOverview(records: [finished], live: [live], calls: [completedAPI],
                                    active: [activeAPI], model: "全部模型", effort: "全部等级",
                                    range: .allTime, bounds: bounds)
        precondition(running.completedCalls == 2 && running.activeCalls == 1)
        precondition(running.groups.count == 1 && running.groups[0].total == 160)
        precondition(running.groups[0].modelCalls == 3 && running.groups[0].activeCalls == 1)
        precondition(running.chart.reduce(0) { $0 + $1.tokens } == 160)
        let newlyFinished = RequestMetric(turnID: "live", timestamp: timestamp, model: "gpt-6-sol",
                                          effort: "high", ttftMS: 300, durationMS: 1_000,
                                          usage: liveUsage, modelCalls: 1, source: "test")
        let settled = buildOverview(records: [finished, newlyFinished], live: [], calls: [completedAPI],
                                    active: [], model: "全部模型", effort: "全部等级",
                                    range: .allTime, bounds: bounds)
        precondition(settled.completedCalls == 2 && settled.activeCalls == 0)
        precondition(settled.groups[0].total == 160 && settled.groups[0].modelCalls == 2)

        let instant = ISO8601DateFormatter().date(from: timestamp)!
        let exactBounds = StatsDateBounds(start: instant, end: instant, includesEnd: true)
        let laterLive = LiveRequest(turnID: "later", timestamp: "2026-09-23T08:00:00.500Z",
                                    model: "gpt-6-sol", effort: "high", usage: liveUsage,
                                    modelCalls: 1, source: "test")
        let exact = buildOverview(records: [finished], live: [laterLive], calls: [], active: [],
                                  model: "全部模型", effort: "全部等级", range: .custom, bounds: exactBounds)
        precondition(exact.groups.count == 1 && exact.groups[0].total == 110,
                     "Inclusive second boundary must exclude later fractional timestamps")

        let manyCalls = Array(repeating: completedAPI, count: 25_000)
        let started = CFAbsoluteTimeGetCurrent()
        let large = buildOverview(records: [finished], live: [live], calls: manyCalls,
                                  active: [activeAPI], model: "全部模型", effort: "全部等级",
                                  range: .allTime, bounds: bounds)
        precondition(large.groups.count == 1 && large.activeCalls == 1)
        print(String(format: "25k-call overview aggregation: %.3fs", CFAbsoluteTimeGetCurrent() - started))
    }
#endif

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === consoleTable ? consoleRows.count : groupRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        if tableView === consoleTable { return consoleCell(column: tableColumn, row: row) }
        return statsCell(column: tableColumn, row: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === consoleTable, row < consoleRows.count else { return tableView.rowHeight }
        return consoleRows[row].hasModelMismatch ? 74 : 58
    }

    private func statsCell(column: NSTableColumn, row: Int) -> NSView? {
        guard row < groupRows.count else { return nil }
        let stats = groupRows[row]
        let id = column.identifier
        let cell = reusableCell(in: tableView, id: id)
        let value: String
        switch id.rawValue {
        case "group": value = "\(stats.model) · \(stats.effort)" + (stats.activeCalls > 0 ? " · \(stats.activeCalls) 进行中" : "")
        case "count": value = compactNumber(stats.modelCalls)
        case "total": value = compactNumber(stats.total)
        case "value": value = stats.cost.pricedCalls + stats.cost.unpricedCalls == 0 && stats.activeCalls > 0
            ? "待完成" : formatAPICost(stats.cost)
        case "input": value = compactNumber(stats.input)
        case "output": value = compactNumber(stats.output)
        case "reasoning": value = compactNumber(stats.reasoning)
        case "rate": value = formatTokenRate(stats.tokenRate)
        case "typical": value = stats.completedTurns == 0 || stats.typicalTTFT == 0 ? "--" : formatDuration(stats.typicalTTFT)
        case "slower": value = stats.completedTurns == 0 || stats.slowerTTFT == 0 ? "--" : formatDuration(stats.slowerTTFT)
        case "duration": value = stats.completedTurns == 0 ? "--" : formatDuration(stats.averageDuration)
        case "cache": value = percent(stats.cacheRate)
        default: value = ""
        }
        cell.textField?.stringValue = value
        cell.textField?.alignment = .left
        switch id.rawValue {
        case "group": cell.toolTip = value
        case "count": cell.toolTip = "\(stats.modelCalls - stats.activeCalls) 次已完成 · \(stats.activeCalls) 次进行中"
        case "total": cell.toolTip = fullNumber(stats.total) + " Token"
        case "input": cell.toolTip = fullNumber(stats.input) + " Token"
        case "output": cell.toolTip = fullNumber(stats.output) + " Token"
        case "reasoning": cell.toolTip = fullNumber(stats.reasoning) + " Token"
        case "value": cell.toolTip = value == "待完成"
            ? "进行中调用尚无最终用量，完成后才能估算价值" : costSummaryTooltip(stats.cost)
        case "rate": cell.toolTip = "该模型已完成调用的输出 Token ÷ 出字阶段总耗时；缺少可信时序的调用不参与计算"
        default: cell.toolTip = nil
        }
        return cell
    }

    private func consoleCell(column: NSTableColumn, row: Int) -> NSView? {
        guard row < consoleRows.count else { return nil }
        let item = consoleRows[row]
        let id = column.identifier
        if id.rawValue == "api_model" {
            return consoleModelCell(item: item, identifier: id)
        }
        if id.rawValue == "api_session" {
            let cell = reusableCell(in: consoleTable, id: id)
            cell.textField?.stringValue = compactSessionTitle(item.sessionName)
            cell.textField?.font = .systemFont(ofSize: 11, weight: .medium)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .left
            cell.toolTip = item.sessionName
            return cell
        }

        let cell = (consoleTable.makeView(withIdentifier: id, owner: self) as? ConsoleDetailCellView)
            ?? ConsoleDetailCellView()
        cell.identifier = id
        switch id.rawValue {
        case "api_event":
            let kind = item.operation == "compaction" ? "压缩" : "模型调用"
            cell.configure(primary: item.status.map { "● \($0)" } ?? "已完成",
                           secondary: "\(clockLabel(item.timestamp)) · \(kind)",
                           primaryColor: item.status != nil ? .controlAccentColor : .labelColor,
                           secondaryColor: item.operation == "compaction" ? .systemOrange : .secondaryLabelColor,
                           toolTip: "\(item.timestamp)\n\(kind) · \(item.status ?? "已完成")")
        case "api_performance":
            let compacting = item.operation == "compaction"
            let unreliableTTFT = item.usage.map {
                hasImplausibleEstimatedTTFT(outputTokens: $0.output, ttftMS: item.ttftMS,
                                            durationMS: item.durationMS, estimated: item.ttftEstimated)
            } ?? false
            let first = compacting ? "不适用" : timingLabel(unreliableTTFT ? nil : item.ttftMS, estimated: item.ttftEstimated)
            let duration = timingLabel(item.durationMS, estimated: item.durationEstimated)
            let rate = compacting ? "不适用" : formatTokenRate(item.tokenRate)
            let details = compacting
                ? "上下文压缩没有可观测的首 Token 或流式生成区间"
                : unreliableTTFT ? "首 Token 事件不可靠，已隐藏估算；速率仅在可信时序下计算"
                : "首 Token \(item.ttftMS.map { "\($0)ms" } ?? "未知") · 总时长 \(item.durationMS.map { "\($0)ms" } ?? "未知")\n速率 = 输出 Token ÷ 出字阶段耗时"
            cell.configure(primary: compacting ? "总 \(duration)" : "首 \(first)  ·  总 \(duration)",
                           secondary: "速率 \(rate)", toolTip: details)
        case "api_usage":
            if let usage = item.usage {
                let hasDetails = usageHasBreakdown(usage)
                let breakdown = hasDetails
                    ? "入 \(compactNumber(usage.input))  ·  缓 \(compactNumber(usage.cached))  ·  出 \(compactNumber(usage.output))  ·  推 \(compactNumber(usage.reasoning))"
                    : "旧记录无输入 / 缓存 / 输出明细"
                let details = hasDetails
                    ? "总 \(fullNumber(usage.total)) · 输入 \(fullNumber(usage.input)) · 缓存输入 \(fullNumber(usage.cached)) · 输出 \(fullNumber(usage.output)) · 推理 \(fullNumber(usage.reasoning)) Token\n缓存是输入的子集，推理是输出的子集"
                    : "总 \(fullNumber(usage.total)) Token；旧记录无法可靠拆分用量"
                cell.configure(primary: "总 \(compactNumber(usage.total)) Token", secondary: breakdown,
                               primaryColor: .labelColor, toolTip: details)
            } else {
                cell.configure(primary: "--", secondary: "等待用量回报", toolTip: "进行中的调用尚无 Token 用量")
            }
        case "api_value":
            let usage = item.usage
            let model = item.responseModel ?? item.model
            let cost = usage.flatMap { estimatedAPICost(model: model, serviceTier: item.serviceTier, usage: $0) }
            let subtitle = usage == nil ? "等待完成" : cost == nil ? "未定价" : "API 等价"
            let tip = usage.map {
                usageHasBreakdown($0)
                    ? pricingTooltip(model: model, serviceTier: item.serviceTier, usage: $0)
                    : "旧版记录缺少输入/缓存/输出拆分，无法可靠估算等价花费"
            } ?? "进行中的调用尚无 Token 用量"
            cell.configure(primary: formatUSD(cost), secondary: subtitle,
                           primaryColor: cost == nil ? .secondaryLabelColor : .labelColor,
                           toolTip: tip)
        default:
            cell.configure(primary: "", secondary: "")
        }
        return cell
    }

    private func consoleModelCell(item: ConsoleRow,
                                  identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let cell = (consoleTable.makeView(withIdentifier: identifier, owner: self) as? ConsoleModelCellView)
            ?? ConsoleModelCellView()
        cell.identifier = identifier
        cell.configure(requestedModel: item.model, responseModel: item.responseModel,
                       effort: item.effort, serviceTier: item.serviceTier)
        return cell
    }

    private func reusableCell(in table: NSTableView, id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = (table.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = id
        if cell.textField == nil {
            let text = NSTextField(labelWithString: "")
            text.font = table === consoleTable ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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

private final class ConsoleDetailCellView: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let contentStack: NSStackView

    override init(frame frameRect: NSRect) {
        contentStack = NSStackView(views: [primaryLabel, secondaryLabel])
        super.init(frame: frameRect)
        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        secondaryLabel.font = .systemFont(ofSize: 10, weight: .regular)
        for label in [primaryLabel, secondaryLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(primary: String, secondary: String,
                   primaryColor: NSColor = .labelColor,
                   secondaryColor: NSColor = .secondaryLabelColor,
                   toolTip: String? = nil) {
        primaryLabel.stringValue = primary
        primaryLabel.textColor = primaryColor
        secondaryLabel.stringValue = secondary
        secondaryLabel.textColor = secondaryColor
        self.toolTip = toolTip
        setAccessibilityLabel(primary + "; " + secondary)
    }
}

private final class ConsoleModelCellView: NSTableCellView {
    private let requestedLabel = NSTextField(labelWithString: "")
    private let effortLabel = NSTextField(labelWithString: "")
    private let tierIcon = NSImageView()
    private let responseLabel = NSTextField(labelWithString: "")
    private let mismatchBadge = MismatchBadgeView()
    private let metadataRow: NSStackView
    private let responseRow: NSStackView
    private let contentStack: NSStackView

    override init(frame frameRect: NSRect) {
        metadataRow = NSStackView(views: [effortLabel, tierIcon])
        responseRow = NSStackView(views: [responseLabel, mismatchBadge])
        contentStack = NSStackView(views: [requestedLabel, metadataRow, responseRow])
        super.init(frame: frameRect)

        requestedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        requestedLabel.textColor = .labelColor
        requestedLabel.lineBreakMode = .byTruncatingTail
        requestedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        effortLabel.font = .systemFont(ofSize: 10, weight: .medium)
        effortLabel.textColor = .secondaryLabelColor
        tierIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        tierIcon.contentTintColor = .systemYellow
        tierIcon.setContentHuggingPriority(.required, for: .horizontal)
        metadataRow.orientation = .horizontal
        metadataRow.alignment = .centerY
        metadataRow.spacing = 5

        responseLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        responseLabel.textColor = .systemOrange
        responseLabel.lineBreakMode = .byTruncatingTail
        responseLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        responseRow.orientation = .horizontal
        responseRow.alignment = .centerY
        responseRow.spacing = 6
        responseRow.setHuggingPriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(requestedModel: String, responseModel: String?, effort: String, serviceTier: String?) {
        requestedLabel.stringValue = requestedModel
        effortLabel.stringValue = "思考 · \(effort)"
        let tier = serviceTier?.lowercased()
        let symbol = tier == "ultrafast" ? "bolt.circle.fill"
            : ["priority", "fast"].contains(tier ?? "") ? "bolt.fill" : nil
        tierIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: fastTierLabel(serviceTier)) }
        tierIcon.isHidden = tierIcon.image == nil
        let tierDescription = serviceTier.map { fastTierLabel($0) } ?? "档位未知"
        guard let responseModel,
              normalizedModelName(requestedModel) != normalizedModelName(responseModel) else {
            responseRow.isHidden = true
            toolTip = responseModel == nil
                ? "请求模型：\(requestedModel)\n思考等级：\(effort) · \(tierDescription)\n本地事件未包含上游响应模型"
                : "请求模型与上游响应模型一致：\(requestedModel)\n思考等级：\(effort) · \(tierDescription)"
            return
        }
        responseLabel.stringValue = "↳ 上游响应：\(responseModel)"
        responseRow.isHidden = false
        toolTip = "请求模型：\(requestedModel)\n上游响应模型：\(responseModel)\n思考等级：\(effort) · \(tierDescription)"
    }
}

private final class MismatchBadgeView: NSView {
    private let label = NSTextField(labelWithString: "模型不一致")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
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
        let barWidth = points.count == 1 ? 28 : max(2, min(18, slot * 0.64))
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
        if points.count == 1, let item = points.first {
            let text = dayLabel(item.date)
            let width = (text as NSString).size(withAttributes: textAttributes(.secondaryLabelColor)).width
            drawText(text, at: NSPoint(x: plot.midX - width / 2, y: 3), color: .secondaryLabelColor)
        } else if let first = points.first, let last = points.last {
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

private func fastTierLabel(_ serviceTier: String?) -> String {
    switch serviceTier?.lowercased() {
    case "ultrafast": return "Ultra Fast"
    case "priority", "fast": return "Fast"
    case "default", "standard": return "标准"
    case .some(let value): return value
    case .none: return "--"
    }
}

private func timingLabel(_ milliseconds: Int?, estimated: Bool?) -> String {
    guard let milliseconds else { return "--" }
    return (estimated == true ? "≈ " : "") + formatDuration(milliseconds)
}

private func hasImplausibleEstimatedTTFT(outputTokens: Int, ttftMS: Int?,
                                         durationMS: Int?, estimated: Bool?) -> Bool {
    guard estimated == true, outputTokens > 0,
          let ttftMS, let durationMS, durationMS > ttftMS else { return false }
    let generationMS = durationMS - ttftMS
    return generationMS < 250 || Double(outputTokens) * 1_000 / Double(generationMS) > 1_000
}

private func tokenRate(for call: APICallMetric) -> Double? {
    guard call.usage.output > 0,
          let ttftMS = call.ttftMS,
          let durationMS = call.durationMS,
          durationMS > ttftMS else { return nil }
    let rate = Double(call.usage.output) * 1_000 / Double(durationMS - ttftMS)
    // Some Codex logs emit only a completed-item event. Its timestamp is not a
    // first-token timestamp, even though it can be just milliseconds before the
    // end. Do not present the resulting tens-of-thousands tk/s as throughput.
    guard !hasImplausibleEstimatedTTFT(outputTokens: call.usage.output,
                                      ttftMS: ttftMS, durationMS: durationMS,
                                      estimated: call.ttftEstimated) else { return nil }
    return rate
}

private func aggregateTokenRate(_ calls: [APICallMetric]) -> Double? {
    var outputTokens = 0
    var generationMS = 0
    for call in calls {
        guard tokenRate(for: call) != nil,
              call.usage.output > 0,
              let ttftMS = call.ttftMS,
              let durationMS = call.durationMS,
              durationMS > ttftMS else { continue }
        outputTokens += call.usage.output
        generationMS += durationMS - ttftMS
    }
    guard outputTokens > 0, generationMS > 0 else { return nil }
    return Double(outputTokens) * 1_000 / Double(generationMS)
}

private func formatTokenRate(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "--" }
    if value >= 1_000 { return String(format: "%.2fk tk/s", value / 1_000) }
    if value >= 100 { return String(format: "%.0f tk/s", value) }
    if value >= 10 { return String(format: "%.1f tk/s", value) }
    return String(format: "%.2f tk/s", value)
}

private func elapsedMS(since timestamp: String) -> Int {
    guard let start = metricDate(timestamp) else { return 0 }
    return max(0, Int(Date().timeIntervalSince(start) * 1_000))
}

private func normalizedModelName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
private func fullNumber(_ value: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) }

private struct APIPrice {
    let name: String
    let input: Double
    let cached: Double
    let output: Double
    let tier: String
    let longContext: Bool
}

private func matchesModel(_ model: String, _ base: String) -> Bool {
    model == base || model.hasPrefix(base + "-20")
}

private func apiPrice(for rawModel: String, serviceTier: String?, inputTokens: Int) -> APIPrice? {
    let model = rawModel.lowercased()
    let tier = serviceTier?.lowercased() ?? "default"
    guard tier != "ultrafast" else { return nil } // No published Ultrafast rate card.
    guard ["default", "standard", "priority", "fast"].contains(tier) else { return nil }
    let fast = tier == "priority" || tier == "fast"
    let longContext = inputTokens > 272_000
    let rateMultiplier = fast ? 2.0 : 1.0
    let inputMultiplier = longContext ? 2.0 : 1.0
    let outputMultiplier = longContext ? 1.5 : 1.0
    let tierName = fast ? "Fast" : "标准"
    func latest(_ name: String, _ input: Double, _ cached: Double, _ output: Double) -> APIPrice {
        APIPrice(name: name, input: input * inputMultiplier * rateMultiplier,
                 cached: cached * inputMultiplier * rateMultiplier,
                 output: output * outputMultiplier * rateMultiplier,
                 tier: tierName, longContext: longContext)
    }
    func standard(_ name: String, _ input: Double, _ cached: Double, _ output: Double) -> APIPrice? {
        guard !fast else { return nil }
        return APIPrice(name: name, input: input, cached: cached, output: output,
                        tier: "标准", longContext: false)
    }
    if matchesModel(model, "gpt-6-astra") {
        return latest("GPT-6 Astra", 10, 1, 50)
    }
    if matchesModel(model, "gpt-6-sol") {
        return latest("GPT-6 Sol", 2, 0.2, 10)
    }
    if matchesModel(model, "gpt-6-luna") {
        return latest("GPT-6 Luna", 0.1, 0.01, 0.5)
    }
    if matchesModel(model, "gpt-5.6-sol") || matchesModel(model, "gpt-5.6") {
        return latest("GPT-5.6 Sol", 4, 0.4, 20)
    }
    if matchesModel(model, "gpt-5.6-terra") {
        return latest("GPT-5.6 Terra", 2, 0.2, 12)
    }
    if matchesModel(model, "gpt-5.6-luna") {
        return latest("GPT-5.6 Luna", 0.2, 0.02, 1.2)
    }
    if matchesModel(model, "gpt-5.5-pro") {
        return standard("GPT-5.5 Pro", 30, 30, 180)
    }
    if matchesModel(model, "gpt-5.5") {
        return standard("GPT-5.5", 5, 0.5, 30)
    }
    if matchesModel(model, "gpt-5.4-pro") {
        return standard("GPT-5.4 Pro", 30, 30, 180)
    }
    if matchesModel(model, "gpt-5.4-mini") {
        return standard("GPT-5.4 Mini", 0.75, 0.075, 4.5)
    }
    if matchesModel(model, "gpt-5.4-nano") {
        return standard("GPT-5.4 Nano", 0.2, 0.02, 1.25)
    }
    if matchesModel(model, "gpt-5.4") {
        return standard("GPT-5.4", 2.5, 0.25, 15)
    }
    if matchesModel(model, "gpt-5.3-codex") || model == "codex-auto-review" {
        let multiplier = fast ? 2.0 : 1.0
        return APIPrice(name: "GPT-5.3-Codex", input: 1.75 * multiplier,
                        cached: 0.175 * multiplier, output: 14 * multiplier,
                        tier: tierName, longContext: false)
    }
    if matchesModel(model, "gpt-5.2-pro") {
        return standard("GPT-5.2 Pro", 21, 21, 168)
    }
    if matchesModel(model, "gpt-5.2") || matchesModel(model, "gpt-5.2-codex") {
        return standard("GPT-5.2", 1.75, 0.175, 14)
    }
    if matchesModel(model, "gpt-5-codex") || matchesModel(model, "gpt-5") {
        return standard("GPT-5", 1.25, 0.125, 10)
    }
    if model == "codex-mini-latest" {
        return standard("codex-mini-latest", 1.5, 0.375, 6)
    }
    return nil
}

private func estimatedAPICost(model: String, serviceTier: String?, usage: TokenUsage) -> Double? {
    guard let price = apiPrice(for: model, serviceTier: serviceTier, inputTokens: usage.input) else { return nil }
    guard usageHasBreakdown(usage) else { return nil }
    let cachedTokens = min(max(usage.cached, 0), max(usage.input, 0))
    let uncachedTokens = max(usage.input - cachedTokens, 0)
    return (Double(uncachedTokens) * price.input
            + Double(cachedTokens) * price.cached
            + Double(max(usage.output, 0)) * price.output) / 1_000_000
}

private func usageHasBreakdown(_ usage: TokenUsage) -> Bool {
    usage.total == 0 || usage.input > 0 || usage.output > 0
}

struct APICostSummary {
    let knownUSD: Double
    let pricedCalls: Int
    let unpricedCalls: Int
}

func summedAPICost(_ calls: [APICallMetric]) -> APICostSummary {
    var knownUSD = 0.0
    var pricedCalls = 0
    var unpricedCalls = 0
    for call in calls {
        let model = call.responseModel ?? call.model
        if let value = estimatedAPICost(model: model, serviceTier: call.serviceTier, usage: call.usage) {
            knownUSD += value
            pricedCalls += 1
        } else {
            unpricedCalls += 1
        }
    }
    return APICostSummary(knownUSD: knownUSD, pricedCalls: pricedCalls, unpricedCalls: unpricedCalls)
}

func formatAPICost(_ summary: APICostSummary) -> String {
    if summary.unpricedCalls == 0 { return formatUSD(summary.knownUSD) }
    if summary.pricedCalls == 0 { return "未定价" }
    return "≥ " + formatUSD(summary.knownUSD).replacingOccurrences(of: "≈ ", with: "")
}

private func costSummaryTooltip(_ summary: APICostSummary) -> String {
    let known = "已按对应 API 档位计价 \(summary.pricedCalls) 次：\(formatUSD(summary.knownUSD))。"
    if summary.unpricedCalls == 0 { return known + "\n估算值不代表订阅套餐或第三方渠道的实际账单。" }
    return known + "\n另有 \(summary.unpricedCalls) 次价格未知（如 Ultra Fast 未公布单价、第三方模型或缺少 Token 拆分）；显示的是已知部分下限，不代表实际账单。"
}

func formatUSD(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value > 0 && value < 0.01 { return String(format: "≈ $%.4f", value) }
    if value < 1_000 { return String(format: "≈ $%.2f", value) }
    if value < 1_000_000 { return String(format: "≈ $%.2fK", value / 1_000) }
    return String(format: "≈ $%.2fM", value / 1_000_000)
}

private func pricingTooltip(model: String, serviceTier: String?, usage: TokenUsage) -> String {
    if serviceTier?.lowercased() == "ultrafast" {
        return "Ultra Fast 目前为限量预览，OpenAI 尚未公布该档位的每百万 Token 单价；不能沿用标准或 Fast 价。"
    }
    guard let price = apiPrice(for: model, serviceTier: serviceTier, inputTokens: usage.input) else {
        return "没有可匹配的该模型／服务档位官方 API 价格，暂不估算；第三方渠道可能另有报价。"
    }
    guard let value = estimatedAPICost(model: model, serviceTier: serviceTier, usage: usage) else {
        return "该调用缺少输入与输出 Token 拆分，无法可靠估算价值"
    }
    let mapping = model.lowercased() == "codex-auto-review" ? "；codex-auto-review 按 GPT-5.3-Codex 计算" : ""
    let context = price.longContext ? "长上下文" : "普通上下文"
    return String(format: "%@ · %@ · %@ API 价：输入 $%.3g/M · 缓存 $%.3g/M · 输出 $%.3g/M%@\n（总输入 − 缓存输入）× 输入价 + 缓存输入 × 缓存价 + 输出 × 输出价\n估算价值 %@；未计不可观测的缓存写入和工具费，不代表实际账单",
                  price.name, price.tier, context, price.input, price.cached, price.output, mapping, formatUSD(value))
}

#if PRICING_TESTS
func runPricingRegressionTests() {
    func approx(_ actual: Double?, _ expected: Double) {
        assert(actual.map { abs($0 - expected) < 0.000_001 } == true,
               "Expected \(expected), got \(String(describing: actual))")
    }
    let short = TokenUsage(input: 200_000, cached: 100_000, output: 10_000,
                           reasoning: 0, total: 210_000)
    approx(estimatedAPICost(model: "gpt-6-sol", serviceTier: "default", usage: short), 0.32)
    approx(estimatedAPICost(model: "gpt-6-sol", serviceTier: "fast", usage: short), 0.64)
    approx(estimatedAPICost(model: "gpt-6-luna", serviceTier: "default", usage: short), 0.016)
    let long = TokenUsage(input: 300_000, cached: 100_000, output: 10_000,
                          reasoning: 0, total: 310_000)
    approx(estimatedAPICost(model: "gpt-6-sol", serviceTier: "default", usage: long), 0.99)
    approx(estimatedAPICost(model: "gpt-5.6-sol", serviceTier: "priority", usage: long), 3.96)
    assert(estimatedAPICost(model: "gpt-5.6-sol", serviceTier: "ultrafast", usage: short) == nil)
    assert(estimatedAPICost(model: "zai-org/GLM-5.3-Flash", serviceTier: "default", usage: short) == nil)
    func call(_ model: String, _ tier: String?, _ usage: TokenUsage, _ ttft: Int = 0, _ duration: Int = 0) -> APICallMetric {
        APICallMetric(id: model, sessionID: "s", turnID: "t", timestamp: "2026-09-23T00:00:00Z",
                      model: model, responseModel: nil, effort: "medium", serviceTier: tier,
                      ttftMS: ttft, ttftEstimated: true, durationMS: duration,
                      durationEstimated: true, operation: nil, usage: usage, source: "test")
    }
    let summary = summedAPICost([call("gpt-6-sol", "default", short),
                                 call("gpt-5.6-sol", "ultrafast", short)])
    approx(summary.knownUSD, 0.32)
    assert(summary.pricedCalls == 1 && summary.unpricedCalls == 1)
    assert(formatAPICost(summary) == "≥ $0.32")
    let bogusRate = call("gpt-5.6-sol", "ultrafast", short, 13_860, 13_870)
    assert(tokenRate(for: bogusRate) == nil)
    let credibleRate = call("gpt-5.6-sol", "ultrafast", short, 1_000, 11_000)
    approx(tokenRate(for: credibleRate), 1_000)
}
#endif

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

private func compactSessionTitle(_ rawTitle: String) -> String {
    var title = rawTitle.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if title.hasPrefix("["), let closing = title.range(of: "](") {
        title = String(title[title.index(after: title.startIndex)..<closing.lowerBound])
    }
    let limit = 14
    guard title.count > limit else { return title }
    return String(title.prefix(limit)) + "…"
}
