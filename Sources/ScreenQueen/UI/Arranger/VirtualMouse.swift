import QuartzCore
import SwiftUI

/// The ghost of the *active* screen (the one under the cursor), shown on every other
/// screen. There is only ONE set of chrome per canvas — no parallel ghost structure.
/// Active: normal place, normal look. Inactive: the same controls in the same
/// map-relative place, each restyled pink *in its own look* (`GhostTintable`) — no flat
/// overlay. Plus a ghost mouse (`GhostCursorLayer`) mirrored onto this canvas via
/// `ghostPoint`, moved on every mouse event.
enum VirtualMouse {
    /// Feature flag: the ghost mouse.
    static let ghostMouseEnabled = true
    /// Feature flag: pink chrome on inactive displays.
    static let ghostChromeEnabled = true

    /// The one ghost tint — hot pink from the seam palette.
    static var pink: NSColor { SeamPalette.colors[0] }
}

/// A chrome element that wears the ghost tint *in its own look* (pink glass, pink
/// track, pink outline) rather than hiding under a flat overlay.
@MainActor protocol GhostTintable: AnyObject {
    func setGhost(_ on: Bool)
}

/// The ghost mouse: a dashed, glowing, translucent hot-pink arrow. Obviously a ghost.
/// Its `position` is the arrow's *tip* (anchor at the top-left of the glyph).
final class GhostCursorLayer: CAShapeLayer {

    override init() {
        super.init()
        let art: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.9, y: 12.8),
            CGPoint(x: 6.3, y: 18.4), CGPoint(x: 9.0, y: 17.2), CGPoint(x: 6.6, y: 11.6),
            CGPoint(x: 12.0, y: 11.6),
        ]
        let s: CGFloat = 1.35
        let h: CGFloat = 18.4 * s
        let path = CGMutablePath()
        path.addLines(between: art.map { CGPoint(x: $0.x * s, y: h - $0.y * s) })
        path.closeSubpath()
        self.path = path
        bounds = CGRect(x: 0, y: 0, width: 12.0 * s, height: h)
        anchorPoint = CGPoint(x: 0, y: 1)           // the tip is the hotspot
        let pink = SeamPalette.colors[0]
        fillColor = pink.withAlphaComponent(0.35).cgColor
        strokeColor = pink.cgColor
        lineWidth = 2
        lineDashPattern = [4, 3]
        lineJoin = .round
        opacity = 0.95
        shadowColor = pink.cgColor
        shadowOpacity = 0.9
        shadowRadius = 6
        shadowOffset = .zero
        isHidden = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - The ghost projection (per-canvas chrome rendering lives in Arranger+Chrome)

extension Arranger {

    /// Map a point from the active canvas's view coords onto this canvas (the ghost
    /// mapping for the mouse and tooltip). Identity when active.
    func ghostPoint(_ p: CGPoint) -> CGPoint {
        ArrangerGeometry.ghostPoint(p, ghostScale: ghostScale, activeCenter: ghostActiveCenter,
                                    destCenter: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Move the ghost mouse — position only, the per-event path. Its *size* is applied
    /// in `renderChrome`, which runs whenever the scale can actually change.
    func updateGhostArrow(cursorActivePoint: CGPoint?, isActive: Bool) {
        guard VirtualMouse.ghostMouseEnabled else { return }
        let arrow = ensureGhostArrow()
        guard !isActive, let p = cursorActivePoint else { arrow.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.position = ghostPoint(p)
        arrow.isHidden = false
        CATransaction.commit()
    }

    private func ensureGhostArrow() -> GhostCursorLayer {
        if let a = ghostArrow { return a }
        wantsLayer = true
        let a = GhostCursorLayer()
        a.zPosition = 6
        let s = chromeTileScale
        a.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
        layer?.addSublayer(a)
        ghostArrow = a
        return a
    }

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
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height)
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
