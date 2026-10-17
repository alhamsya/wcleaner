import AppKit
import QuartzCore
import WCleanerCore

/// What the summary card at the top of the status menu shows. Pure value, built from a snapshot.
struct MenuSummary: Equatable {
    enum Tone: Equatable {
        case neutral
        case positive
        case caution
    }

    var isChecking: Bool
    var status: String
    var statusDetail: String
    var overview: String
    /// Share (0…1) of the measured worktree size that already passed every safety check.
    var freeableFraction: Double
    var freeable: String
    var hasFreeable: Bool
    var safe = 0
    var waiting = 0
    var review = 0
    var kept = 0
    var automatic: String
    var automaticTone: Tone

    init(snapshot: MonitorSnapshot, settings: AppSettings, now: Date) {
        isChecking = snapshot.isScanning
        if snapshot.isScanning {
            status = "Checking…"
        } else if let completed = snapshot.lastScanCompletedAt {
            status = "Checked \(EnglishDateFormat.relative(completed, now: now))"
        } else {
            status = "Not checked yet"
        }
        if let next = snapshot.nextScanAt, next > now, !snapshot.isScanning {
            statusDetail = "Next check at \(EnglishDateFormat.time.format(next))"
        } else {
            statusDetail = status
        }

        let worktrees = snapshot.allLinkedWorktrees
        let total = snapshot.totalUsage
        let opportunity = snapshot.cleanupOpportunity
        if worktrees.isEmpty {
            overview = snapshot.repositories.isEmpty ? "No repositories yet" : "No linked worktrees"
        } else {
            overview = "\(worktrees.count) worktree\(worktrees.count == 1 ? "" : "s") · \(total.displayString)"
        }
        hasFreeable = opportunity.itemCount > 0
        freeable = hasFreeable ? "\(opportunity.displayString) freeable" : "Nothing to free"
        freeableFraction = total.bytes > 0 ? min(max(Double(opportunity.bytes) / Double(total.bytes), 0), 1) : 0

        for worktree in worktrees {
            switch worktree.decision.verdict {
            case .eligible: safe += 1
            case .waiting: waiting += 1
            case .needsReview: review += 1
            case .blocked: kept += 1
            }
        }

        if !settings.autoCleanupEnabled {
            automatic = "Auto cleanup off"
            automaticTone = .neutral
        } else if settings.autoCleanupPaused {
            automatic = "Auto cleanup paused"
            automaticTone = .caution
        } else {
            automatic = "Auto cleanup on"
            automaticTone = .positive
        }
    }

    var accessibilityText: String {
        [
            "WCleaner", status, overview, freeable, automatic,
            "\(safe) safe, \(waiting) waiting, \(review) to review, \(kept) kept",
        ].joined(separator: ". ")
    }
}

/// Verdict colours shared by the summary card and the worktree rows.
enum VerdictStyle {
    static func color(_ verdict: CleanupDecision.Verdict) -> NSColor {
        switch verdict {
        case .eligible: .systemGreen
        case .waiting: .systemBlue
        case .needsReview: .systemOrange
        case .blocked: .systemGray
        }
    }
}

/// The card at the top of the status menu. Plain AppKit; it is refreshed in place while the menu is open.
@MainActor
final class MenuSummaryView: NSView {
    static let width: CGFloat = 400

    /// Runs a check. The button lives in the card so the menu stays open while WCleaner checks.
    var onCheckNow: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = MenuSummaryView.label(.boldSystemFont(ofSize: 13), color: .labelColor)
    private let spinner = NSProgressIndicator()
    private let statusLabel = MenuSummaryView.label(.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let overviewLabel = MenuSummaryView.label(.systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let automaticLabel = MenuSummaryView.label(.systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private let bar = CapsuleBar()
    private let freeableLabel = MenuSummaryView.label(.monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
    private(set) lazy var checkButton: NSButton = {
        let button = NSButton(title: "Check Now", target: self, action: #selector(checkPressed))
        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = "Check all repositories now. The menu stays open."
        return button
    }()
    private let chips: [Chip] = [
        Chip(title: "Safe", color: VerdictStyle.color(.eligible)),
        Chip(title: "Waiting", color: VerdictStyle.color(.waiting(until: .distantFuture))),
        Chip(title: "Review", color: VerdictStyle.color(.needsReview)),
        Chip(title: "Kept", color: VerdictStyle.color(.blocked)),
    ]
    private(set) var summary: MenuSummary

    init(summary: MenuSummary) {
        self.summary = summary
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        autoresizingMask = [.width]
        build()
        apply(summary, animated: false)
        let height = fittingSize.height
        setFrameSize(NSSize(width: Self.width, height: height))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
        ])
        titleLabel.stringValue = "WCleaner"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)

        let titleColumn = NSStackView(views: [titleLabel, overviewLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 1

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 4
        let statusColumn = NSStackView(views: [statusRow, checkButton])
        statusColumn.orientation = .vertical
        statusColumn.alignment = .trailing
        statusColumn.spacing = 4

        let header = NSStackView(views: [iconView, titleColumn, NSView(), statusColumn])
        header.spacing = 8
        header.alignment = .centerY

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        freeableLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let usage = NSStackView(views: [bar, freeableLabel])
        usage.spacing = 8
        usage.alignment = .centerY

        let chipRow = NSStackView(views: chips)
        chipRow.spacing = 12
        chipRow.setHuggingPriority(.required, for: .horizontal)
        let footer = NSStackView(views: [chipRow, NSView(), automaticLabel])
        footer.spacing = 8
        footer.alignment = .centerY

        let content = NSStackView(views: [header, usage, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            usage.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    @objc private func checkPressed() {
        onCheckNow?()
    }

    func apply(_ summary: MenuSummary, animated: Bool = true) {
        let previous = self.summary
        self.summary = summary
        statusLabel.stringValue = summary.status
        statusLabel.toolTip = summary.statusDetail
        overviewLabel.stringValue = summary.overview
        automaticLabel.stringValue = summary.automatic
        automaticLabel.textColor = switch summary.automaticTone {
        case .neutral: .secondaryLabelColor
        case .positive: .systemGreen
        case .caution: .systemOrange
        }
        freeableLabel.stringValue = summary.freeable
        freeableLabel.textColor = summary.hasFreeable ? .systemGreen : .secondaryLabelColor
        bar.setFraction(summary.freeableFraction, animated: animated && summary.freeableFraction != previous.freeableFraction)
        for (chip, count) in zip(chips, [summary.safe, summary.waiting, summary.review, summary.kept]) {
            chip.count = count
        }
        if summary.isChecking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        checkButton.isEnabled = !summary.isChecking
        setAccessibilityLabel(summary.accessibilityText)
    }

    /// Fills the bar from empty; called when the menu opens.
    func playEntrance() {
        bar.setFraction(summary.freeableFraction, animated: true, fromZero: true)
    }

    private static func label(_ font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        return label
    }
}

/// A dot and a count, e.g. "● 2 Safe". Zero counts are faded.
@MainActor
private final class Chip: NSStackView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private let color: NSColor

    var count = 0 {
        didSet { refresh() }
    }

    init(title: String, color: NSColor) {
        self.title = title
        self.color = color
        super.init(frame: .zero)
        spacing = 4
        alignment = .centerY
        setHuggingPriority(.required, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.setAccessibilityElement(false)
        addArrangedSubview(dot)
        addArrangedSubview(label)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        label.stringValue = "\(count) \(title)"
        label.textColor = count > 0 ? .labelColor : .tertiaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color.withAlphaComponent(count > 0 ? 1 : 0.3).cgColor
        }
    }
}

/// A thin capsule progress bar whose fill can glide to a new value.
@MainActor
final class CapsuleBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var fraction: Double = 0
    var fillColor: NSColor = .systemGreen {
        didSet { updateColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        layer?.addSublayer(track)
        setAccessibilityElement(false)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.bounds = CGRect(x: 0, y: 0, width: fillWidth(fraction), height: bounds.height)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Sets the fill. The animation scales the fill horizontally, so it stays correct when the menu
    /// resizes the bar while it plays.
    func setFraction(_ value: Double, animated: Bool, fromZero: Bool = false) {
        let previous = fraction
        fraction = min(max(value, 0), 1)
        needsLayout = true
        guard animated, fraction > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let startScale = fromZero ? 0 : previous / fraction
        guard startScale != 1 else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = startScale
        animation.toValue = 1
        animation.duration = 0.45
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fill.add(animation, forKey: "fill")
    }

    private func fillWidth(_ fraction: Double) -> CGFloat {
        guard fraction > 0 else { return 0 }
        // A visible sliver for tiny but non-zero values.
        return max(bounds.width * fraction, bounds.height)
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
            fill.backgroundColor = fillColor.cgColor
        }
    }
}
