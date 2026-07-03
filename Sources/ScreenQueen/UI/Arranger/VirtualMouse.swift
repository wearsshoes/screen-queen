import AppKit

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

    /// The minimap scale (view px per plane inch) at which chrome renders at natural
    /// size. Bar, ghost mouse, and granny viewer all scale by `transform.scale / this`
    /// (`chromeTileScale`) — the one knob for their absolute size.
    static let referenceMinimapScale: CGFloat = 40

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

// MARK: - Per-canvas rendering

extension Arranger {

    /// Render the chrome for this display's mode. `active` is the canvas under the
    /// cursor (nil ⇒ this one is it). All chrome is laid out at this canvas's own tile
    /// scale at its shared anchor spot; ghost mode only changes the tint.
    func renderChrome(active: Arranger?) {
        guard VirtualMouse.ghostChromeEnabled else { return }
        let inactive = active != nil && active !== self
        isGhost = inactive   // so syncButtons tints rebuilt icons to match this mode
        let myT = drawTransform(currentRects())
        if inactive, let myT, myT.scale > 0,
           let actT = active!.drawTransform(active!.currentRects()), actT.scale > 0 {
            // Ratio of the two canvases' minimap scales: a cursor beside a tile on the
            // active screen lands beside the matching tile here.
            ghostScale = myT.scale / actT.scale
            ghostActiveCenter = CGPoint(x: active!.bounds.midX, y: active!.bounds.midY)
        } else {
            ghostScale = 1
            ghostActiveCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // One transform per pass: the bar re-renders at the pass's scale + ghost state
        // (SwiftUI rebuild — tint and sizing are part of the model), then is frame-placed
        // through the same `chromeViewRect` as the granny viewer; the footer tracks the
        // settled bar; the ghost mouse's size rides the same scale.
        if let myT, myT.scale > 0 {
            let k = chromeTileScale(myT)
            updateBar(scale: k)
            layoutBar(in: myT)
            layoutFooter(scale: k)
            if let arrow = ghostArrow {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                arrow.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
                CATransaction.commit()
            }
        } else {
            updateBar()   // no transform yet — still reflect the fresh ghost state
        }
        solvePanel.setGhost(inactive)
    }

    /// Sizes the chrome in proportion to this canvas's minimap tiles: the minimap scale
    /// over a reference, so bigger tiles → bigger bar.
    func chromeTileScale(_ t: Transform) -> CGFloat {
        t.scale / VirtualMouse.referenceMinimapScale
    }

    /// The current tile scale, computing the transform itself; 1 if it isn't ready.
    /// Inside a render pass prefer `chromeTileScale(_:)` with the pass's one transform.
    var chromeTileScale: CGFloat {
        guard let t = drawTransform(currentRects()), t.scale > 0 else { return 1 }
        return chromeTileScale(t)
    }

    /// Map a point from the active canvas's view coords onto this canvas (the ghost
    /// mapping for the mouse and tooltip). Identity when active.
    func ghostPoint(_ p: CGPoint) -> CGPoint {
        ArrangerGeometry.ghostPoint(p, ghostScale: ghostScale, activeCenter: ghostActiveCenter,
                                    destCenter: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Round to the nearest whole *device* pixel — a fractional origin smears content
    /// across pixel boundaries.
    func pixelSnap(_ v: CGFloat) -> CGFloat {
        ArrangerGeometry.pixelSnap(v, backingScale: window?.backingScaleFactor ?? 2)
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
