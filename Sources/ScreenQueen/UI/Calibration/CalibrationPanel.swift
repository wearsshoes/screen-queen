import SwiftUI

/// The native control surface for match calibration: a small floating HUD panel
/// with a quiet instruction, a prominent live inferred-diagonal readout, and
/// Save/Cancel — instead of bare buttons floating on the dimmed overlay.
/// SwiftUI content in an NSPanel shell (the shell keeps the floating/nonactivating
/// behavior, the shielding-plus-one level, and the arrow-key nudge routing).
@MainActor
final class CalibrationPanel: NSPanel {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Arrow-key fine adjustment, forwarded to the target tape (± points, ⇧ = ×10).
    var onNudge: ((CGFloat) -> Void)?

    private let displayName: String
    private let claimedInches: Double
    /// A previous calibration's diagonal, when one is stored (0 = never measured).
    private let lastMeasuredInches: Double
    private var inferredInches: Double = 0

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
        let host = NSHostingView(rootView: makeView())
        contentView = host
        setContentSize(host.fittingSize)
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

    private func makeView() -> CalibrationPanelView {
        CalibrationPanelView(displayName: displayName, claimedInches: claimedInches,
                             lastMeasuredInches: lastMeasuredInches, inferredInches: inferredInches,
                             save: { [weak self] in self?.onSave?() },
                             cancel: { [weak self] in self?.onCancel?() })
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
            let barX = f.maxX - CalibrationMath.barEdgeInset - Tape.thickness
            origin = NSPoint(x: barX - frame.width - gap, y: f.minY + a.along - frame.height / 2)
        case .left:
            let barX = f.minX + CalibrationMath.barEdgeInset + Tape.thickness
            origin = NSPoint(x: barX + gap, y: f.minY + a.along - frame.height / 2)
        case .top:
            let barY = f.maxY - CalibrationMath.barEdgeInset - Tape.thickness
            origin = NSPoint(x: f.minX + a.along - frame.width / 2, y: barY - frame.height - gap)
        case .bottom:
            let barY = f.minY + CalibrationMath.barEdgeInset + Tape.thickness
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
        inferredInches = inches
        (contentView as? NSHostingView<CalibrationPanelView>)?.rootView = makeView()
    }
}

/// The panel's content: title, instruction, the live readout, receipts, Save/Cancel.
struct CalibrationPanelView: View {
    var displayName: String
    var claimedInches: Double
    var lastMeasuredInches: Double
    var inferredInches: Double
    var save: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(displayName)
                .font(.system(size: 15, weight: .semibold))
            Text(Copy.matchInstruction)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .padding(.bottom, 6)
            Text(Copy.matchReadoutCaption)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(inferredInches > 0 ? String(format: "%.1f″", inferredInches) : Copy.matchReadoutPlaceholder)
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .padding(.bottom, 2)
            // What we measured last time (when there's a prior calibration on file), and
            // what the monitor itself claims — for contrast with the live measurement.
            if lastMeasuredInches > 0 {
                Text(Copy.matchPriorLine(String(format: "%.1f", lastMeasuredInches)))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if claimedInches > 0 {
                Text(Copy.matchClaimLine(String(format: "%.1f", claimedInches)))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button(Copy.cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                // Focus follows the cursor between screens, so the panel under the
                // user's hand is always the key one — its Make It Canon wears the
                // accent when it matters.
                Button(Copy.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .frame(width: 320)
        // A modern rounded translucent card (popover material), not the dated HUD frame.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
