import AppKit
import QuartzCore

private let premiumGold = NSColor(calibratedRed: 0.91, green: 0.70, blue: 0.24, alpha: 1)

final class StatusPopoverController: NSViewController {
    var onRefresh: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
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
    private weak var refreshButton: NSButton?
    private var refreshing = false

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        preferredContentSize = NSSize(width: 398, height: 390)

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
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])

        content.addArrangedSubview(makeHeader())
        content.addArrangedSubview(makeQuotaCard())
        content.addArrangedSubview(resetCard)
        setupResetCard()
        content.addArrangedSubview(makeStatsRow())
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }

    func setLoading() {
        setRefreshing(true)
        ring.remaining = nil
        planLabel.stringValue = "LOADING"
        windowTitle.stringValue = "正在刷新"
        quotaDetail.stringValue = "loading"
        progress.usedPercent = nil
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
        let remaining = max(0, 100 - (mainUsed ?? 0))
        ring.remaining = snapshot == nil ? nil : remaining
        windowTitle.stringValue = windowName(mainMinutes)
        quotaDetail.stringValue = mainUsed.map { "已用 \($0)%  ·  剩余 \(max(0, 100 - $0))%" } ?? "额度暂时无法读取"
        progress.usedPercent = mainUsed
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

    private func makeHeader() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        let icon = NSImageView(); icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath); icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let title = label("Codex Pulse", size: 17, weight: .semibold)
        row.addArrangedSubview(icon); row.addArrangedSubview(title); row.addArrangedSubview(NSView()); row.addArrangedSubview(updatedLabel)
        let refresh = iconButton("arrow.triangle.2.circlepath.circle", toolTip: "立即刷新", action: #selector(refreshNow))
        refreshButton = refresh
        row.addArrangedSubview(refresh)
        if refreshing { startRefreshAnimation(on: refresh) }
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
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 38), image.heightAnchor.constraint(equalToConstant: 38)])
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

    private func stat(_ title: String, _ value: NSTextField) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 3
        stack.addArrangedSubview(value); stack.addArrangedSubview(label(title, size: 11, color: .secondaryLabelColor)); return stack
    }

    private func iconButton(_ symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) ?? NSImage(), target: self, action: action)
        button.isBordered = false; button.toolTip = toolTip; button.contentTintColor = .secondaryLabelColor; return button
    }

    func setRefreshing(_ value: Bool) {
        refreshing = value
        guard let button = refreshButton else { return }
        if value {
            startRefreshAnimation(on: button)
        } else {
            button.layer?.removeAnimation(forKey: "codex-pulse-refresh-spin")
            button.layer?.setAffineTransform(.identity)
            button.contentTintColor = .secondaryLabelColor
        }
    }

    private func startRefreshAnimation(on button: NSButton) {
        guard button.layer?.animation(forKey: "codex-pulse-refresh-spin") == nil else { return }
        button.wantsLayer = true
        button.contentTintColor = .systemBlue
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 0.75
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        button.layer?.add(spin, forKey: "codex-pulse-refresh-spin")
    }

    @objc private func refreshNow() { onRefresh?() }
    @objc private func openDashboard() { onOpenDashboard?() }
    @objc private func quitApp() { onQuit?() }
}

private final class QuotaProgressView: NSView {
    var usedPercent: Int? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        track.fill()
        guard let usedPercent else { return }
        let width = rect.width * CGFloat(max(0, min(100, usedPercent))) / 100
        guard width > 0 else { return }
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, width), height: rect.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }
}

private final class ResetCreditIconView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = premiumGold.cgColor
        layer?.cornerRadius = 19
        let image = NSImageView(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重置") ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        image.contentTintColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)])
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
