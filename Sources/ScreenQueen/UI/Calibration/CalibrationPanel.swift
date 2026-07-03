import AppKit

/// The native control surface for match calibration: a small floating HUD panel
/// with a quiet instruction, a prominent live inferred-diagonal readout, and
/// Save/Cancel — instead of bare buttons floating on the dimmed overlay.
@MainActor
final class CalibrationPanel: NSPanel {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Arrow-key fine adjustment, forwarded to the target tape (± points, ⇧ = ×10).
    var onNudge: ((CGFloat) -> Void)?

    private let valueLabel = NSTextField(labelWithString: Copy.matchReadoutPlaceholder)
    private let displayName: String
    private let claimedInches: Double
    /// A previous calibration's diagonal, when one is stored (0 = never measured).
    private let lastMeasuredInches: Double

    init(displayName: String, claimedInches: Double, lastMeasuredInches: Double) {
        self.displayName = displayName
        self.claimedInches = claimedInches
        self.lastMeasuredInches = lastMeasuredInches
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 214),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Above the shielding-level overlay windows so the panel stays reachable.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        buildContent()
    }

    override var canBecomeKey: Bool { true }

    /// Arrow keys nudge the target tape without stealing Save (⏎) or Cancel (⎋).
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 124, 126: onNudge?(step)     // → / ↑
        case 123, 125: onNudge?(-step)    // ← / ↓
        default: super.keyDown(with: event)
        }
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: displayName)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let instruction = NSTextField(wrappingLabelWithString:
            Copy.matchInstruction)
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        instruction.preferredMaxLayoutWidth = 260

        let caption = NSTextField(labelWithString: Copy.matchReadoutCaption)
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center

        // What the monitor itself claims, for contrast with the live measurement —
        // and what we measured last time, when there's a prior calibration on file.
        let claim = NSTextField(labelWithString:
            claimedInches > 0 ? Copy.matchClaimLine(String(format: "%.1f", claimedInches)) : "")
        claim.font = .systemFont(ofSize: 11)
        claim.textColor = .tertiaryLabelColor
        claim.alignment = .center
        claim.isHidden = claimedInches <= 0

        let receipts = NSTextField(labelWithString:
            lastMeasuredInches > 0 ? Copy.matchPriorLine(String(format: "%.1f", lastMeasuredInches)) : "")
        receipts.font = .systemFont(ofSize: 11)
        receipts.textColor = .tertiaryLabelColor
        receipts.alignment = .center
        receipts.isHidden = lastMeasuredInches <= 0

        let cancel = NSButton(title: Copy.cancel, target: self, action: #selector(cancelTapped))
        cancel.controlSize = .large; cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: Copy.save, target: self, action: #selector(saveTapped))
        save.controlSize = .large; save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        // The modern prominent (accent-filled) default button. Focus follows the
        // cursor between screens, so the panel under the user's hand is always
        // the key one — its Make It Canon wears the accent when it matters.
        save.bezelColor = .controlAccentColor

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [title, instruction, caption, valueLabel, receipts, claim, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.setCustomSpacing(16, after: instruction)
        stack.setCustomSpacing(2, after: caption)
        stack.setCustomSpacing(2, after: valueLabel)
        stack.setCustomSpacing(2, after: receipts)
        stack.setCustomSpacing(18, after: claim)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A modern rounded translucent card (popover material), not the dated HUD frame.
        let card = NSVisualEffectView()
        card.material = .popover
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        contentView = card
        setContentSize(card.fittingSize)   // the claim line made the fixed rect a lie
    }

    /// Show the panel on `screen`, near the target bar (`anchor`) but inset toward the
    /// screen's center so it doesn't cover the bar.
    func present(on screen: NSScreen, near a: BarPlacement) {
        let vis = screen.visibleFrame
        let gap: CGFloat = 40
        // `a.along` is the bar's center in the screen's local frame; convert to global.
        // The bar hugs `a.edge` (inset from it); place the panel just inward of the bar,
        // aligned to its midpoint.
        let f = screen.frame
        var origin: NSPoint
        switch a.edge {
        case .right:
            let barX = f.maxX - CalibrationMath.barEdgeInset - TapeView.thickness
            origin = NSPoint(x: barX - frame.width - gap, y: f.minY + a.along - frame.height / 2)
        case .left:
            let barX = f.minX + CalibrationMath.barEdgeInset + TapeView.thickness
            origin = NSPoint(x: barX + gap, y: f.minY + a.along - frame.height / 2)
        case .top:
            let barY = f.maxY - CalibrationMath.barEdgeInset - TapeView.thickness
            origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY - frame.height - gap)
        case .bottom:
            let barY = f.minY + CalibrationMath.barEdgeInset + TapeView.thickness
            origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY + gap)
        }

        // Keep the panel fully on the visible screen.
        origin.x = min(max(origin.x, vis.minX + 12), vis.maxX - frame.width - 12)
        origin.y = min(max(origin.y, vis.minY + 12), vis.maxY - frame.height - 12)
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
    }

    /// Update the prominent readout with the currently inferred diagonal in inches.
    func setInferredDiagonal(_ inches: Double) {
        valueLabel.stringValue = inches > 0 ? String(format: "%.1f″", inches) : Copy.matchReadoutPlaceholder
    }

    @objc private func saveTapped() { onSave?() }
    @objc private func cancelTapped() { onCancel?() }
}
