import SwiftUI

/// The control surface for match calibration: a floating HUD card with a quiet
/// instruction, a prominent live inferred-diagonal readout, and Save/Cancel.
/// An island on each calibration window (see CalibrationController) — the window
/// shell handles keying and arrow-nudge routing; this is pure content.
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
                // Focus follows the cursor between screens, so the window under the
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

/// The panel island's hosting view (a subview of the calibration window's scene,
/// not its own NSPanel). Swallows its own clicks; everything else falls through
/// to the tapes.
final class CalibrationPanelHost: NSHostingView<CalibrationPanelView> {

    /// The panel's origin near the target bar (`anchor`), inset toward the screen's
    /// center so it doesn't cover the bar. Window-local y-up coordinates; clamped
    /// to the screen's visible frame.
    static func origin(near a: BarPlacement, screen: NSScreen, panelSize: NSSize) -> NSPoint {
        let f = screen.frame
        let gap: CGFloat = 40
        var origin: NSPoint
        switch a.edge {
        case .right:
            let barX = f.width - CalibrationMath.barEdgeInset - Tape.thickness
            origin = NSPoint(x: barX - panelSize.width - gap, y: a.along - panelSize.height / 2)
        case .left:
            let barX = CalibrationMath.barEdgeInset + Tape.thickness
            origin = NSPoint(x: barX + gap, y: a.along - panelSize.height / 2)
        case .top:
            let barY = f.height - CalibrationMath.barEdgeInset - Tape.thickness
            origin = NSPoint(x: a.along - panelSize.width / 2, y: barY - panelSize.height - gap)
        case .bottom:
            let barY = CalibrationMath.barEdgeInset + Tape.thickness
            origin = NSPoint(x: a.along - panelSize.width / 2, y: barY + gap)
        }
        // Keep the panel fully on the visible screen (local coordinates).
        let vis = screen.visibleFrame.offsetBy(dx: -f.minX, dy: -f.minY)
        origin.x = min(max(origin.x, vis.minX + 12), vis.maxX - panelSize.width - 12)
        origin.y = min(max(origin.y, vis.minY + 12), vis.maxY - panelSize.height - 12)
        return origin
    }
}
