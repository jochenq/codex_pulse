import AppKit
import QuartzCore

private let premiumGold = NSColor(calibratedRed: 0.91, green: 0.70, blue: 0.24, alpha: 1)

final class StatusPopoverController: NSViewController {
    var onRefresh: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onOpenTibo: (() -> Void)?
    var onConfigureAI: (() -> Void)?
    var onRefreshTibo: (() -> Void)?
    var onQuit: (() -> Void)?

    private let ring = QuotaRingView()
    private let planLabel = label("LOADING", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let windowTitle = label("7 天窗口", size: 14, weight: .semibold)
    private let quotaDetail = label("正在读取额度…", size: 12, color: .secondaryLabelColor)
    private let resetLabel = label("", size: 12, color: .secondaryLabelColor)
    private let progress = QuotaProgressView()
    private let shortQuotaLabel = label("", size: 12, color: .secondaryLabelColor)
    private let resetCard = PremiumResetCardView()
    private let resetCountLabel = label("0", size: 32, weight: .semibold, color: premiumGold)
    private let resetExpiryLabel = label("暂无可用重置卡", size: 12, color: NSColor.white.withAlphaComponent(0.74))
    private let callsValue = label("--", size: 18, weight: .semibold)
    private let tokensValue = label("--", size: 18, weight: .semibold)
    private let costValue = label("--", size: 18, weight: .semibold)
    private let updatedLabel = label("", size: 11, color: .tertiaryLabelColor)
    private let tiboHeadline = label("正在获取公开动态", size: 13, weight: .semibold)
    private let tiboSummary = label("首次分析完成后会显示在这里。", size: 11, color: .secondaryLabelColor)
    private let tiboReply = label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let tiboLocalTime = label("地点与时区未知", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let tiboMeta = label("尚未检查", size: 10, color: .tertiaryLabelColor)
    private let tiboAvatar = NSImageView(image: NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Tibo 头像") ?? NSImage())
    private let tiboSectionTitle = label("Tibo", size: 12, weight: .semibold)
    private let tiboStateLabel = label("动态", size: 12, weight: .semibold, color: .systemGreen)
    private weak var refreshButton: RefreshIconButton?
    private var refreshing = false
    private var loadedTiboAvatarURL: String?
    private var latestTiboSnapshot: TiboActivitySnapshot?
    private var tiboClockTimer: Timer?

    deinit { tiboClockTimer?.invalidate() }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        preferredContentSize = NSSize(width: 398, height: 600)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])

        content.addArrangedSubview(makeHeader())
        content.addArrangedSubview(makeQuotaCard())
        content.addArrangedSubview(resetCard)
        setupResetCard()
        content.addArrangedSubview(makeStatsRow())
        content.addArrangedSubview(makeTiboCard())
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let versionBadge = makeVersionBadge()
        root.addSubview(versionBadge)
        NSLayoutConstraint.activate([
            versionBadge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            versionBadge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        let clockTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let snapshot = self.latestTiboSnapshot else { return }
            self.tiboLocalTime.stringValue = tiboPlaceAndTime(snapshot)
        }
        RunLoop.main.add(clockTimer, forMode: .common)
        tiboClockTimer = clockTimer
    }

    func setLoading() {
        setRefreshing(true)
        ring.remaining = nil
        planLabel.stringValue = "LOADING"
        windowTitle.stringValue = "正在刷新"
        quotaDetail.stringValue = "loading"
        progress.elapsedPercent = nil
        resetLabel.stringValue = ""
        shortQuotaLabel.isHidden = true
        callsValue.stringValue = "loading"
        tokensValue.stringValue = "loading"
        costValue.stringValue = "loading"
        updatedLabel.stringValue = "刷新中…"
    }

    func update(snapshot: RateLimitReader.Snapshot?, todayCalls: Int, todayTokens: Int,
                todayCost: Double?, refreshedAt: Date) {
        setRefreshing(false)
        let mainUsed = snapshot?.secondaryUsed ?? snapshot?.primaryUsed
        let mainMinutes = snapshot?.secondaryUsed != nil ? snapshot?.secondaryMinutes : snapshot?.primaryMinutes
        let mainReset = snapshot?.secondaryUsed != nil ? snapshot?.secondaryReset : snapshot?.primaryReset
        ring.remaining = mainUsed.map { max(0, 100 - $0) }
        windowTitle.stringValue = windowName(mainMinutes)
        quotaDetail.stringValue = mainUsed.map { "已用 \($0)%  ·  剩余 \(max(0, 100 - $0))%" } ?? "额度暂时无法读取"
        progress.elapsedPercent = resetCycleElapsedPercent(windowMinutes: mainMinutes, resetAt: mainReset)
        progress.toolTip = progress.elapsedPercent.map { "重置周期已过去 \($0)%" } ?? "重置周期暂不可用"
        resetLabel.stringValue = mainReset.map { "重置于 \(fullDate($0))  ·  \(relativeTime($0))" } ?? "重置时间暂不可用"
        let plan = (snapshot?.plan ?? "--").uppercased()
        let credits = snapshot?.credits.map { String(format: "%.2f", $0) } ?? "--"
        planLabel.stringValue = "\(plan)  ·  Credits \(credits)"

        if snapshot?.secondaryUsed != nil, let used = snapshot?.primaryUsed {
            shortQuotaLabel.isHidden = false
            shortQuotaLabel.stringValue = "\(windowName(snapshot?.primaryMinutes))：已用 \(used)% · 剩余 \(max(0, 100 - used))%" + (snapshot?.primaryReset.map { " · \(relativeTime($0))重置" } ?? "")
        } else {
            shortQuotaLabel.isHidden = true
        }

        let resetCount = snapshot?.resetCreditCount ?? 0
        resetCountLabel.stringValue = "\(resetCount)"
        resetExpiryLabel.stringValue = snapshot?.resetCreditExpiry.map { "最近到期  \(fullDate($0))" } ?? (resetCount > 0 ? "到期时间暂不可用" : "暂无可用重置卡")
        resetCard.isHidden = snapshot?.resetCreditCount == nil

        callsValue.stringValue = compactNumber(todayCalls)
        tokensValue.stringValue = compactNumber(todayTokens)
        costValue.stringValue = formatUSD(todayCost)
        updatedLabel.stringValue = "更新于 " + timeOnly(refreshedAt)
    }

    func updateTibo(_ snapshot: TiboActivitySnapshot) {
        latestTiboSnapshot = snapshot
        tiboStateLabel.stringValue = displayTiboState(snapshot)
        tiboHeadline.stringValue = displayTiboHeadline(snapshot.headline)
        tiboSummary.stringValue = snapshot.summary
        if let reply = snapshot.latestReplyText, !reply.isEmpty {
            tiboReply.stringValue = "最新回复 · " + reply
            tiboReply.isHidden = false
        } else {
            tiboReply.isHidden = true
        }
        tiboLocalTime.stringValue = tiboPlaceAndTime(snapshot)
        loadTiboAvatar(snapshot.avatarURL)
        let checked = snapshot.checkedAt == .distantPast ? "尚未检查" : "检查于 \(timeOnly(snapshot.checkedAt))"
        let latest = snapshot.latestPostAt.map { " · 最近发帖 \(shortActivityDate($0))" } ?? ""
        switch snapshot.status {
        case "current":
            tiboMeta.stringValue = checked + latest
        case "current-fallback":
            tiboMeta.stringValue = "原文回退 · " + checked + latest
        case "loading":
            tiboMeta.stringValue = "正在更新 Tibo 动态…"
        case "missing-configuration":
            tiboMeta.stringValue = "请配置 AI 服务 · " + checked
        default:
            tiboMeta.stringValue = "本次检查未完成，保留上次摘要 · " + checked
        }
    }

    private func makeHeader() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        let icon = NSImageView(); icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath); icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let title = label("Codex Pulse", size: 15, weight: .semibold)
        row.addArrangedSubview(icon); row.addArrangedSubview(title); row.addArrangedSubview(NSView()); row.addArrangedSubview(updatedLabel)
        let refresh = RefreshIconButton(target: self, action: #selector(refreshNow))
        refreshButton = refresh
        row.addArrangedSubview(refresh)
        refresh.setSpinning(refreshing)
        row.addArrangedSubview(iconButton("chart.bar.xaxis", toolTip: "打开统计面板", action: #selector(openDashboard)))
        let quit = iconButton("power", toolTip: "退出 Codex Pulse", action: #selector(quitApp))
        row.addArrangedSubview(quit)
        return row
    }

    private func makeQuotaCard() -> NSView {
        let card = CardView(tint: .systemBlue)
        let vertical = NSStackView(); vertical.orientation = .vertical; vertical.alignment = .leading; vertical.spacing = 9; vertical.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(vertical)
        NSLayoutConstraint.activate([
            vertical.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), vertical.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            vertical.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), vertical.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        let top = NSStackView(); top.orientation = .horizontal; top.alignment = .centerY; top.spacing = 12
        let names = NSStackView(); names.orientation = .vertical; names.alignment = .leading; names.spacing = 4
        let member = NSStackView(); member.orientation = .horizontal; member.alignment = .centerY; member.spacing = 7
        let crown = NSImageView(image: NSImage(systemSymbolName: "crown.fill", accessibilityDescription: "会员") ?? NSImage())
        crown.contentTintColor = .systemYellow
        member.addArrangedSubview(label("Codex", size: 19, weight: .semibold)); member.addArrangedSubview(crown)
        names.addArrangedSubview(member); names.addArrangedSubview(planLabel)
        top.addArrangedSubview(names); top.addArrangedSubview(NSView()); top.addArrangedSubview(ring)
        NSLayoutConstraint.activate([ring.widthAnchor.constraint(equalToConstant: 70), ring.heightAnchor.constraint(equalToConstant: 70)])
        vertical.addArrangedSubview(top); top.widthAnchor.constraint(equalTo: vertical.widthAnchor).isActive = true
        let titleRow = NSStackView(); titleRow.orientation = .horizontal; titleRow.addArrangedSubview(windowTitle); titleRow.addArrangedSubview(NSView()); titleRow.addArrangedSubview(quotaDetail)
        vertical.addArrangedSubview(titleRow); titleRow.widthAnchor.constraint(equalTo: vertical.widthAnchor).isActive = true
        vertical.addArrangedSubview(progress)
        NSLayoutConstraint.activate([progress.widthAnchor.constraint(equalTo: vertical.widthAnchor), progress.heightAnchor.constraint(equalToConstant: 8)])
        vertical.addArrangedSubview(resetLabel); vertical.addArrangedSubview(shortQuotaLabel)
        card.heightAnchor.constraint(equalToConstant: 185).isActive = true
        return card
    }

    private func setupResetCard() {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = false
        resetCard.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: resetCard.leadingAnchor, constant: 15), row.trailingAnchor.constraint(equalTo: resetCard.trailingAnchor, constant: -15), row.topAnchor.constraint(equalTo: resetCard.topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: resetCard.bottomAnchor, constant: -12)])
        let image = ResetCreditIconView()
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 40), image.heightAnchor.constraint(equalToConstant: 60)])
        let text = NSStackView(); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        let titleRow = NSStackView(); titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 6
        titleRow.addArrangedSubview(label("重置卡", size: 15, weight: .semibold, color: premiumGold))
        let sparkle = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        sparkle.contentTintColor = premiumGold
        titleRow.addArrangedSubview(sparkle)
        text.addArrangedSubview(titleRow); text.addArrangedSubview(resetExpiryLabel)
        let count = NSStackView(); count.orientation = .vertical; count.alignment = .centerX; count.spacing = 0
        count.addArrangedSubview(resetCountLabel); count.addArrangedSubview(label("枚可用", size: 11, weight: .medium, color: premiumGold.withAlphaComponent(0.82)))
        row.addArrangedSubview(image); row.addArrangedSubview(text); row.addArrangedSubview(NSView()); row.addArrangedSubview(count)
    }

    private func makeStatsRow() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
        row.addArrangedSubview(stat("今日调用次数", callsValue)); row.addArrangedSubview(stat("今日 Token 总数", tokensValue)); row.addArrangedSubview(stat("今日等价花费", costValue))
        return row
    }

    private func makeTiboCard() -> NSView {
        let card = TiboActivityCardView()
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 5; content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 158),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 13),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -13),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)
        ])
        let header = NSStackView(); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 7
        tiboAvatar.imageScaling = .scaleProportionallyUpOrDown
        tiboAvatar.wantsLayer = true
        tiboAvatar.layer?.cornerRadius = 11
        tiboAvatar.layer?.masksToBounds = true
        NSLayoutConstraint.activate([tiboAvatar.widthAnchor.constraint(equalToConstant: 22), tiboAvatar.heightAnchor.constraint(equalToConstant: 22)])
        header.addArrangedSubview(tiboAvatar)
        header.addArrangedSubview(tiboSectionTitle)
        header.addArrangedSubview(tiboStateLabel)
        let settings = iconButton("slider.horizontal.3", toolTip: "配置 Tibo AI", action: #selector(configureAI))
        settings.controlSize = .small
        settings.contentTintColor = .secondaryLabelColor
        header.addArrangedSubview(settings)
        let refresh = iconButton("arrow.clockwise", toolTip: "强制刷新 Tibo 动态", action: #selector(refreshTiboNow))
        refresh.controlSize = .small
        refresh.contentTintColor = .secondaryLabelColor
        header.addArrangedSubview(refresh)
        header.addArrangedSubview(NSView())
        let source = ClickableButton(title: "查看", target: self, action: #selector(openTibo))
        source.image = xBrandIcon()
        source.imagePosition = .imageRight
        source.imageHugsTitle = true
        source.toolTip = "在 X 中查看"
        source.isBordered = false; source.font = .systemFont(ofSize: 10, weight: .medium); source.contentTintColor = .secondaryLabelColor
        header.addArrangedSubview(source)
        content.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(tiboHeadline)
        tiboSummary.lineBreakMode = .byWordWrapping
        tiboSummary.maximumNumberOfLines = 3
        tiboSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(tiboSummary); tiboSummary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tiboReply.lineBreakMode = .byTruncatingTail
        content.addArrangedSubview(tiboReply); tiboReply.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(tiboLocalTime)
        content.addArrangedSubview(tiboMeta)
        return card
    }

    private func makeVersionBadge() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.12).cgColor
        badge.layer?.cornerRadius = 5
        let text = label("v" + version, size: 8, weight: .medium, color: .tertiaryLabelColor)
        text.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        text.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            text.topAnchor.constraint(equalTo: badge.topAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2)
        ])
        return badge
    }

    private func loadTiboAvatar(_ rawURL: String?) {
        let rawURL = rawURL ?? "https://pbs.twimg.com/profile_images/2075819673263001600/pj1vyX6I.jpg"
        guard rawURL != loadedTiboAvatarURL, let url = URL(string: rawURL) else { return }
        loadedTiboAvatarURL = rawURL
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self?.loadedTiboAvatarURL == rawURL else { return }
                self?.tiboAvatar.image = image
            }
        }.resume()
    }

    private func stat(_ title: String, _ value: NSTextField) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 3
        stack.addArrangedSubview(value); stack.addArrangedSubview(label(title, size: 11, color: .secondaryLabelColor)); return stack
    }

    private func iconButton(_ symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = ClickableButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage(), target: self, action: action)
        button.isBordered = false; button.toolTip = toolTip; button.contentTintColor = .secondaryLabelColor; return button
    }

    func setRefreshing(_ value: Bool) {
        refreshing = value
        refreshButton?.setSpinning(value)
        if value {
            updatedLabel.stringValue = "刷新中…"
        }
    }

    func noteRefreshRequested() {
        refreshButton?.flash()
        updatedLabel.stringValue = "正在刷新…"
    }

    func noteRefreshQueued() {
        refreshButton?.flash()
        updatedLabel.stringValue = "刷新已排队…"
    }

    @objc private func refreshNow() { onRefresh?() }
    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func openTibo() { onOpenTibo?() }
    @objc private func configureAI() { onConfigureAI?() }
    @objc private func refreshTiboNow() { onRefreshTibo?() }
    @objc private func quitApp() { onQuit?() }
}

private final class StatusDotView: NSView {
    var color: NSColor = NSColor(calibratedRed: 0.10, green: 0.82, blue: 0.38, alpha: 1) { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private final class TiboActivityCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.055).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }
}

class ClickableButton: NSButton {
    private var handTrackingArea: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: -3, dy: -3), cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        if let handTrackingArea {
            removeTrackingArea(handTrackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        handTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class RefreshIconButton: ClickableButton {
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        setButtonType(.momentaryPushIn)
        sendAction(on: [.leftMouseDown])
        toolTip = "立即刷新"
        setAccessibilityLabel("刷新用量和 Tibo 动态")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 34)
        ])

        glyph.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "立即刷新")
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = .secondaryLabelColor
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 17),
            glyph.heightAnchor.constraint(equalToConstant: 17)
        ])

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func setSpinning(_ spinning: Bool) {
        if spinning {
            glyph.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            glyph.isHidden = false
        }
    }

    func flash() {
        guard !spinning else { return }
        glyph.contentTintColor = .controlAccentColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.spinning else { return }
            self.glyph.contentTintColor = .secondaryLabelColor
        }
    }

    private var spinning: Bool { !spinner.isDisplayedWhenStopped && glyph.isHidden }
}

private final class QuotaProgressView: NSView {
    var elapsedPercent: Int? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        track.fill()
        guard let elapsedPercent else { return }
        let width = rect.width * CGFloat(max(0, min(100, elapsedPercent))) / 100
        guard width > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, width), height: rect.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
}

private func resetCycleElapsedPercent(windowMinutes: Int?, resetAt: Date?, now: Date = Date()) -> Int? {
    guard let windowMinutes, windowMinutes > 0, let resetAt else { return nil }
    let duration = Double(windowMinutes) * 60
    let elapsed = duration - resetAt.timeIntervalSince(now)
    return max(0, min(100, Int((elapsed / duration * 100).rounded())))
}

private final class ResetCreditIconView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = premiumGold.withAlphaComponent(0.82).cgColor
        let image = NSImageView()
        if let url = Bundle.main.url(forResource: "ResetCardTibo", withExtension: "png") {
            image.image = NSImage(contentsOf: url)
        }
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
    }
    required init?(coder: NSCoder) { nil }
}

private final class PremiumResetCardView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = premiumGold.withAlphaComponent(0.62).cgColor
        gradient.colors = [
            NSColor(calibratedWhite: 0.035, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.16, green: 0.135, blue: 0.075, alpha: 1).cgColor,
            NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.56, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.25)
        gradient.endPoint = CGPoint(x: 1, y: 0.8)
        gradient.cornerRadius = 14
        layer?.insertSublayer(gradient, at: 0)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

private final class CardView: NSView {
    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = tint.withAlphaComponent(0.075).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }
}

private final class QuotaRingView: NSView {
    var remaining: Int? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = bounds.insetBy(dx: 7, dy: 7)
        let center = NSPoint(x: inset.midX, y: inset.midY)
        let radius = min(inset.width, inset.height) / 2
        let start = CGFloat.pi / 2
        let background = NSBezierPath(); background.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360); background.lineWidth = 8
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke(); background.stroke()
        if let remaining {
            let progress = NSBezierPath(); progress.appendArc(withCenter: center, radius: radius, startAngle: start * 180 / .pi, endAngle: (start - 2 * .pi * CGFloat(remaining) / 100) * 180 / .pi, clockwise: true); progress.lineWidth = 8; progress.lineCapStyle = .round
            NSColor.systemBlue.setStroke(); progress.stroke()
        }
        let text = remaining.map { "\($0)%" } ?? "--"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; field.lineBreakMode = .byTruncatingTail; return field
}

private func xBrandIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12))
    image.lockFocus()
    let text = NSAttributedString(string: "𝕏", attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.black
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: (12 - size.width) / 2, y: (12 - size.height) / 2))
    image.unlockFocus()
    image.isTemplate = true
    return image
}

private func shortActivityDate(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return timeOnly(date) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
}

private func tiboPlaceAndTime(_ snapshot: TiboActivitySnapshot) -> String {
    guard let identifier = snapshot.timeZoneIdentifier,
          let timeZone = TimeZone(identifier: identifier) else {
        return "地点与时区未知 · 等待动态证据"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm:ss EEE"
    let location = snapshot.inferredLocation?.isEmpty == false ? snapshot.inferredLocation! : "地点未知"
    let abbreviation = timeZone.abbreviation(for: Date()) ?? identifier
    return "\(location) / \(abbreviation) · \(formatter.string(from: Date())) · AI 据动态判断"
}

private func displayTiboState(_ snapshot: TiboActivitySnapshot) -> String {
    let value = snapshot.activityState?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? "状态未知" : String(value.prefix(5))
}

private func displayTiboHeadline(_ headline: String) -> String {
    let lowered = headline.lowercased()
    if lowered.contains("reset") && (headline.contains("暂无") || headline.contains("没有") || headline.contains("无新")) {
        return "近期公开动态"
    }
    return headline
}

private func windowName(_ minutes: Int?) -> String {
    guard let minutes else { return "额度窗口" }
    if minutes % 10080 == 0 { return "\(minutes / 10080 * 7) 天窗口" }
    if minutes % 60 == 0 { return "\(minutes / 60) 小时窗口" }
    return "\(minutes) 分钟窗口"
}

private func fullDate(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 HH:mm"; return f.string(from: date)
}

private func timeOnly(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm:ss"; return f.string(from: date)
}

private func relativeTime(_ date: Date) -> String {
    let seconds = date.timeIntervalSinceNow
    if seconds <= 0 { return "已到期" }
    let days = Int(seconds / 86400), hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
    if days > 0 { return "还有 \(days) 天 \(hours) 小时" }
    let minutes = Int(seconds / 60)
    if hours > 0 { return "还有 \(hours) 小时 \(max(0, minutes % 60)) 分" }
    return "还有 \(max(1, minutes)) 分钟"
}
