import AppKit

final class StatusPopoverController: NSViewController {
    var onRefresh: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onQuit: (() -> Void)?

    private let ring = QuotaRingView()
    private let planLabel = label("CODEX", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let windowTitle = label("7 天窗口", size: 14, weight: .semibold)
    private let quotaDetail = label("正在读取额度…", size: 12, color: .secondaryLabelColor)
    private let resetLabel = label("", size: 12, color: .secondaryLabelColor)
    private let progress = QuotaProgressView()
    private let shortQuotaLabel = label("", size: 12, color: .secondaryLabelColor)
    private let memberExpiryLabel = label("会员到期：--", size: 12)
    private let creditsLabel = label("Credits：--", size: 12, color: .secondaryLabelColor)
    private let resetCard = CardView(tint: .systemOrange)
    private let resetCountLabel = label("0", size: 32, weight: .semibold)
    private let resetExpiryLabel = label("暂无可用重置卡", size: 12, color: .secondaryLabelColor)
    private let callsValue = label("--", size: 18, weight: .semibold)
    private let tasksValue = label("--", size: 18, weight: .semibold)
    private let activeValue = label("--", size: 18, weight: .semibold)
    private let updatedLabel = label("", size: 11, color: .tertiaryLabelColor)

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        preferredContentSize = NSSize(width: 398, height: 510)

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        content.addArrangedSubview(makeHeader())
        content.addArrangedSubview(makeQuotaCard())
        content.addArrangedSubview(makeMembershipRow())
        content.addArrangedSubview(resetCard)
        setupResetCard()
        content.addArrangedSubview(makeStatsRow())
        content.addArrangedSubview(makeBottomBar())
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }

    func update(snapshot: RateLimitReader.Snapshot?, totalModelCalls: Int, taskCount: Int,
                activeCallCount: Int, refreshedAt: Date) {
        let mainUsed = snapshot?.secondaryUsed ?? snapshot?.primaryUsed
        let mainMinutes = snapshot?.secondaryUsed != nil ? snapshot?.secondaryMinutes : snapshot?.primaryMinutes
        let mainReset = snapshot?.secondaryUsed != nil ? snapshot?.secondaryReset : snapshot?.primaryReset
        let remaining = max(0, 100 - (mainUsed ?? 0))
        ring.remaining = snapshot == nil ? nil : remaining
        windowTitle.stringValue = windowName(mainMinutes)
        quotaDetail.stringValue = mainUsed.map { "已用 \($0)%  ·  剩余 \(max(0, 100 - $0))%" } ?? "额度暂时无法读取"
        progress.usedPercent = mainUsed
        resetLabel.stringValue = mainReset.map { "重置于 \(fullDate($0))  ·  \(relativeTime($0))" } ?? "重置时间暂不可用"
        planLabel.stringValue = (snapshot?.plan ?? "Codex").uppercased()

        if snapshot?.secondaryUsed != nil, let used = snapshot?.primaryUsed {
            shortQuotaLabel.stringValue = "\(windowName(snapshot?.primaryMinutes))：已用 \(used)% · 剩余 \(max(0, 100 - used))%" + (snapshot?.primaryReset.map { " · \(relativeTime($0))重置" } ?? "")
        } else {
            shortQuotaLabel.stringValue = ""
        }
        memberExpiryLabel.stringValue = snapshot?.membershipExpiry.map { "下次续费：\(dateOnly($0))  ·  \(relativeTime($0))" } ?? "下次续费：未设置"
        creditsLabel.stringValue = "Credits：" + (snapshot?.credits.map { String(format: "%.2f", $0) } ?? "--")

        let resetCount = snapshot?.resetCreditCount ?? 0
        resetCountLabel.stringValue = "\(resetCount)"
        resetExpiryLabel.stringValue = snapshot?.resetCreditExpiry.map { "最近到期  \(fullDate($0))" } ?? (resetCount > 0 ? "到期时间暂不可用" : "暂无可用重置卡")
        resetCard.isHidden = snapshot?.resetCreditCount == nil

        callsValue.stringValue = compactNumber(totalModelCalls)
        tasksValue.stringValue = compactNumber(taskCount)
        activeValue.stringValue = "\(activeCallCount)"
        updatedLabel.stringValue = "更新于 " + timeOnly(refreshedAt)
    }

    private func makeHeader() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        let icon = NSImageView(); icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath); icon.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let title = label("Codex Pulse", size: 17, weight: .semibold)
        row.addArrangedSubview(icon); row.addArrangedSubview(title); row.addArrangedSubview(NSView()); row.addArrangedSubview(updatedLabel)
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
        names.addArrangedSubview(label("Codex", size: 19, weight: .semibold)); names.addArrangedSubview(planLabel)
        top.addArrangedSubview(names); top.addArrangedSubview(NSView()); top.addArrangedSubview(ring)
        NSLayoutConstraint.activate([ring.widthAnchor.constraint(equalToConstant: 82), ring.heightAnchor.constraint(equalToConstant: 82)])
        vertical.addArrangedSubview(top); top.widthAnchor.constraint(equalTo: vertical.widthAnchor).isActive = true
        let titleRow = NSStackView(); titleRow.orientation = .horizontal; titleRow.addArrangedSubview(windowTitle); titleRow.addArrangedSubview(NSView()); titleRow.addArrangedSubview(quotaDetail)
        vertical.addArrangedSubview(titleRow); titleRow.widthAnchor.constraint(equalTo: vertical.widthAnchor).isActive = true
        vertical.addArrangedSubview(progress)
        NSLayoutConstraint.activate([progress.widthAnchor.constraint(equalTo: vertical.widthAnchor), progress.heightAnchor.constraint(equalToConstant: 8)])
        vertical.addArrangedSubview(resetLabel); vertical.addArrangedSubview(shortQuotaLabel)
        card.heightAnchor.constraint(equalToConstant: 220).isActive = true
        return card
    }

    private func makeMembershipRow() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "person.crop.circle.badge.checkmark", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemBlue
        row.addArrangedSubview(icon); row.addArrangedSubview(memberExpiryLabel); row.addArrangedSubview(NSView()); row.addArrangedSubview(creditsLabel)
        return row
    }

    private func setupResetCard() {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12; row.translatesAutoresizingMaskIntoConstraints = false
        resetCard.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: resetCard.leadingAnchor, constant: 15), row.trailingAnchor.constraint(equalTo: resetCard.trailingAnchor, constant: -15), row.topAnchor.constraint(equalTo: resetCard.topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: resetCard.bottomAnchor, constant: -12)])
        let image = ResetCreditIconView()
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 38), image.heightAnchor.constraint(equalToConstant: 38)])
        let text = NSStackView(); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        text.addArrangedSubview(label("重置卡", size: 15, weight: .semibold)); text.addArrangedSubview(resetExpiryLabel)
        let count = NSStackView(); count.orientation = .vertical; count.alignment = .centerX; count.spacing = 0
        count.addArrangedSubview(resetCountLabel); count.addArrangedSubview(label("枚可用", size: 11, color: .secondaryLabelColor))
        row.addArrangedSubview(image); row.addArrangedSubview(text); row.addArrangedSubview(NSView()); row.addArrangedSubview(count)
    }

    private func makeStatsRow() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
        row.addArrangedSubview(stat("模型调用", callsValue)); row.addArrangedSubview(stat("任务", tasksValue)); row.addArrangedSubview(stat("进行中", activeValue))
        return row
    }

    private func makeBottomBar() -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshNow)); refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil); refresh.imagePosition = .imageLeading; refresh.bezelStyle = .rounded
        let dashboard = NSButton(title: "打开统计面板", target: self, action: #selector(openDashboard)); dashboard.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil); dashboard.imagePosition = .imageLeading; dashboard.bezelStyle = .rounded; dashboard.keyEquivalent = "\r"
        row.addArrangedSubview(refresh); row.addArrangedSubview(NSView()); row.addArrangedSubview(dashboard)
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
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.systemOrange.setFill()
        circle.fill()

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arrow = NSBezierPath()
        arrow.appendArc(withCenter: center, radius: 10.5, startAngle: 45, endAngle: 320, clockwise: true)
        arrow.lineWidth = 3
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: center.x - 10.2, y: center.y + 2.0))
        head.line(to: NSPoint(x: center.x - 10.4, y: center.y + 10.0))
        head.line(to: NSPoint(x: center.x - 3.0, y: center.y + 7.4))
        head.lineWidth = 3
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
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

private func dateOnly(_ date: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"; return f.string(from: date)
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
