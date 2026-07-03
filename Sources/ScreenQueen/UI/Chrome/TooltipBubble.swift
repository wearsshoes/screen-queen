import SwiftUI

/// The fun tooltip: a white speech-bubble with a hot-pink outline and Comic Sans text,
/// shown on *every* canvas at once via the ghost mapping (a native `NSView.toolTip`
/// would only show on the truly hovered screen). Click-through.
struct TooltipBubbleView: View {
    var text: String

    /// Comic Sans if the system has it, else a rounded fallback that still reads playful.
    private static let font: NSFont =
        NSFont(name: "Comic Sans MS", size: 13)
        ?? NSFont(name: "ChalkboardSE-Regular", size: 13)
        ?? .systemFont(ofSize: 13, weight: .medium)

    var body: some View {
        Text(text)
            .font(Font(Self.font))
            .foregroundStyle(Color(red: 0.86, green: 0.16, blue: 0.5))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(red: 0.95, green: 0.28, blue: 0.6),
                              lineWidth: 2.5))
            .padding(1.5)   // room so the stroke never kisses the hosting frame
    }
}

/// The bubble's hosting view: decoration only, so clicks fall through to the canvas.
final class TooltipHost: NSHostingView<TooltipBubbleView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Canvas plumbing (rides the ghost mapping — see VirtualMouse.swift)

extension Arranger {

    /// The tooltip text for the bar control at `activePoint` (active canvas's coords),
    /// or nil. Called on the active canvas to decide what every canvas shows. Hit rects
    /// come from the SwiftUI side (`barControlFrames`, bar-local top-left space).
    func hoveredTooltip(at activePoint: CGPoint) -> String? {
        guard let host = barHost else { return nil }
        var p = host.convert(activePoint, from: self)
        if !host.isFlipped { p.y = host.bounds.height - p.y }
        for (control, frame) in barControlFrames where frame.contains(p) {
            if barControlEnabled(control) { return tooltipText(for: control) }
        }
        return nil
    }

    /// Show/hide this canvas's tooltip bubble at the ghost-mapped cursor (below-and-right,
    /// clamped on-canvas). Both nil ⇒ hide. The rootView is only swapped on a text change;
    /// the per-event work is a frame move.
    func updateTooltip(text: String?, cursorActivePoint: CGPoint?) {
        guard let text, let p = cursorActivePoint else { tooltipBubble?.isHidden = true; return }
        let host = ensureTooltipBubble()
        if host.rootView.text != text { host.rootView = TooltipBubbleView(text: text) }
        let size = host.fittingSize
        let cursor = ghostPoint(p)
        let gap: CGFloat = 14
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y + gap)
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
        origin.y = min(max(origin.y, 4), bounds.height - size.height - 4)
        host.frame = CGRect(origin: origin, size: size)
        host.isHidden = false
    }

    private func ensureTooltipBubble() -> TooltipHost {
        if let b = tooltipBubble { return b }
        let b = TooltipHost(rootView: TooltipBubbleView(text: ""))
        addSubview(b)
        tooltipBubble = b
        return b
    }
}
