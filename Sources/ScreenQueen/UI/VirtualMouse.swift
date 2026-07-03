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
    /// cursor (nil ⇒ this one is it). Inactive → each chrome view's layer is
    /// transformed to the active screen's perspective and washed pink; active →
    /// identity, no wash. Recomputes the projection affine (also used by the ghost
    /// mouse); called only when the active screen changes.
    func renderChrome(active: Arranger?) {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let inactive = active != nil && active !== self
        ghostAffine = inactive ? affine(from: active!) : .identity
        for view in chromeViews { applyChromeMode(view, inactive: inactive) }
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

    /// Transform + wash one chrome view for the mode. The layer transform reproduces
    /// the canvas-space projection about the view's own centre (so its position and
    /// scale both land right); the pink wash is a sublayer shown only when inactive.
    private func applyChromeMode(_ view: NSView, inactive: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if inactive {
            // Apply the canvas-space affine about the layer's centre: rendered =
            // centre + M(p − centre) needs a transform with M's linear part and a
            // translation of M(centre) − centre.
            let c = CGPoint(x: view.frame.midX, y: view.frame.midY)
            let mc = c.applying(ghostAffine)
            layer.setAffineTransform(CGAffineTransform(
                a: ghostAffine.a, b: ghostAffine.b, c: ghostAffine.c, d: ghostAffine.d,
                tx: mc.x - c.x, ty: mc.y - c.y))
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
    /// canvas's view coords; it rides the *same* affine as the chrome. Hidden on the
    /// active screen (real cursor there).
    func updateGhostArrow(cursorActivePoint: CGPoint?, isActive: Bool) {
        guard VirtualMouse.ghostMouseEnabled else { return }
        let arrow = ensureGhostArrow()
        guard !isActive, let p = cursorActivePoint else { arrow.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.position = p.applying(ghostAffine)
        arrow.isHidden = false
        CATransaction.commit()
    }

    /// The affine mapping the active canvas's view space onto this canvas's, via the
    /// shared plane (both transforms are scale+translate, so the composition is too).
    private func affine(from active: Arranger) -> CGAffineTransform {
        guard let myT = drawTransform(currentRects()),
              let actT = active.drawTransform(active.currentRects()) else { return .identity }
        func map(_ p: CGPoint) -> CGPoint { myT.viewPoint(actT.planePoint(p)) }
        let o = map(.zero), ex = map(CGPoint(x: 1, y: 0)), ey = map(CGPoint(x: 0, y: 1))
        return CGAffineTransform(a: ex.x - o.x, b: ex.y - o.y,
                                 c: ey.x - o.x, d: ey.y - o.y, tx: o.x, ty: o.y)
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
