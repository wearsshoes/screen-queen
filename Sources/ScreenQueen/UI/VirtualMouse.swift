import AppKit

/// The ghost of the *active* screen (the one under the cursor), shown on every other
/// screen. There is only ONE set of chrome per canvas — no parallel ghost structure.
/// Based on whether this display is active, that one chrome:
///
/// - **active**: sits in its normal place, its normal look.
/// - **inactive**: the *same* controls, washed pink and transformed to the active
///   screen's perspective on this canvas's minimap (free to run off-screen).
///
/// Plus a **ghost mouse** (`GhostCursorLayer`): the real cursor mirrored onto this
/// canvas via the same affine, moved on every mouse event.
///
/// The chrome transform is recomputed only when the active screen changes.
enum VirtualMouse {
    /// Feature flag: the ghost mouse (arrow mirrored onto the minimap).
    static let ghostMouseEnabled = true
    /// Feature flag: restyle + project the chrome on inactive displays.
    static let ghostChromeEnabled = true
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
        let pink = ArrangerState.seamPalette[0]
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

// MARK: - Per-canvas rendering

extension Arranger {

    /// Render the chrome for this display's mode. `active` is the canvas under the
    /// cursor (nil ⇒ this one is it). Inactive → each chrome view scales (from the
    /// minimap centre) to the active screen's minimap scale and washes pink; active →
    /// identity, no wash. The minimap centre is the view centre (the union of tiles is
    /// centred there), so the bar — itself centred — moves straight up and down.
    /// Recomputes the scale (also used by the ghost mouse); only on active-screen change.
    func renderChrome(active: Arranger?) {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let inactive = active != nil && active !== self
        if inactive, let myT = drawTransform(currentRects()),
           let actT = active!.drawTransform(active!.currentRects()), actT.scale > 0 {
            ghostScale = myT.scale / actT.scale
            ghostActiveCenter = CGPoint(x: active!.bounds.midX, y: active!.bounds.midY)
        } else {
            ghostScale = 1
            ghostActiveCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for view in chromeViews { applyChromeMode(view, inactive: inactive, scale: ghostScale, center: center) }
    }

    /// The one set of chrome: the button bar, the "what she sees" (granny) panel, and
    /// the countdown banner when it's up. Adding a UI element = add its view here.
    private var chromeViews: [NSView] {
        var views: [NSView] = []
        if let bar = barContainer { views.append(bar) }
        views.append(solvePanel)
        if let banner, !banner.isHidden { views.append(banner) }
        return views
    }

    /// Scale + wash one chrome view for the mode. The layer transform is a uniform
    /// scale about the minimap centre `c` — reproduced about the view's own centre, so
    /// a centred view (the bar) moves straight up/down. The pink wash is a sublayer
    /// shown only when inactive.
    private func applyChromeMode(_ view: NSView, inactive: Bool, scale s: CGFloat, center c: CGPoint) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if inactive {
            let vc = CGPoint(x: view.frame.midX, y: view.frame.midY)
            layer.setAffineTransform(CGAffineTransform(
                a: s, b: 0, c: 0, d: s, tx: (1 - s) * (c.x - vc.x), ty: (1 - s) * (c.y - vc.y)))
        } else {
            layer.setAffineTransform(.identity)
        }
        let wash = chromeWash(on: view)
        wash.frame = view.bounds
        wash.isHidden = !inactive
    }

    /// A translucent pink layer over a chrome view — the "ghost" tint, over the real
    /// controls. One per view, created on demand.
    private func chromeWash(on view: NSView) -> CALayer {
        let key = ObjectIdentifier(view)
        if let wash = chromeWashes[key] { return wash }
        let wash = CALayer()
        wash.backgroundColor = ArrangerState.seamPalette[0].withAlphaComponent(0.42).cgColor
        wash.zPosition = 1000   // over the controls' own sublayers
        wash.isHidden = true
        view.layer?.addSublayer(wash)
        chromeWashes[key] = wash
        return wash
    }

    /// Move the ghost mouse. `cursorActivePoint` is the real cursor in the active
    /// canvas's view coords; it rides the *same* scale-about-centre as the chrome (the
    /// active screen's centre to this canvas's centre). Hidden on the active screen.
    func updateGhostArrow(cursorActivePoint: CGPoint?, isActive: Bool) {
        guard VirtualMouse.ghostMouseEnabled else { return }
        let arrow = ensureGhostArrow()
        guard !isActive, let p = cursorActivePoint else { arrow.isHidden = true; return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.position = CGPoint(x: c.x + ghostScale * (p.x - ghostActiveCenter.x),
                                 y: c.y + ghostScale * (p.y - ghostActiveCenter.y))
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
