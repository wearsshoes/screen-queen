import QuartzCore

/// The ghost of the *active* screen (the one under the cursor), shown on every other
/// screen. There is only ONE set of chrome per stage — no parallel ghost structure.
/// Active: normal place, normal look. Inactive: the same controls in the same
/// map-relative place, each restyled pink *in its own look* (the bar via
/// `BarModel.isGhost`, the panel via `SolvePanelHost.setGhost`) — no flat overlay. Plus a ghost mouse (`GhostCursorLayer`) mirrored onto this stage via
/// `ghostPoint`, moved on every mouse event. (The tint's SwiftUI currency is
/// `ChromeMetrics.ghostPink`; the tooltip that trails the ghost lives with its bubble
/// in TooltipBubble.swift — this file is QuartzCore-only.)
enum VirtualMouse {
    /// Feature flag: the ghost mouse.
    static let ghostMouseEnabled = true
    /// Feature flag: pink chrome on inactive displays.
    static let ghostChromeEnabled = true
}

/// The ghost mouse: a dashed, glowing, translucent hot-pink arrow. Obviously a ghost.
/// Its `position` is the arrow's *tip* (anchor at the top-left of the glyph).
final class GhostCursorLayer: CAShapeLayer {

    override init() {
        super.init()
        // Art is authored y-down (tip at the origin); the layer rides the flipped
        // stage, so it draws as-is.
        let art: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.9, y: 12.8),
            CGPoint(x: 6.3, y: 18.4), CGPoint(x: 9.0, y: 17.2), CGPoint(x: 6.6, y: 11.6),
            CGPoint(x: 12.0, y: 11.6),
        ]
        let s: CGFloat = 1.35
        let path = CGMutablePath()
        path.addLines(between: art.map { CGPoint(x: $0.x * s, y: $0.y * s) })
        path.closeSubpath()
        self.path = path
        bounds = CGRect(x: 0, y: 0, width: 12.0 * s, height: 18.4 * s)
        anchorPoint = CGPoint(x: 0, y: 0)           // the tip is the hotspot
        let pink = SeamPalette.pink
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

// MARK: - The ghost mouse (the `ghostPoint` projection lives in Stage+Chrome)

extension Stage {

    /// Move the ghost mouse — position only, the per-event path. Like a real cursor
    /// (and its own tooltip), the arrow never changes size.
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
        layer?.addSublayer(a)
        ghostArrow = a
        return a
    }

}
