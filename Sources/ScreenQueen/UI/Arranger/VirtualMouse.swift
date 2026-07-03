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

    /// Feature flag: the beacon (pulsing map-pin on the schematic, every canvas).
    static let planeMarkerEnabled = true
}

/// The beacon: a hot-pink dot with a repeating expanding pulse ring (Find-My style) —
/// a map pin marking the cursor's place on the schematic, on every canvas.
final class PlaneMouseMarkerLayer: CALayer {

    private static let side: CGFloat = 44
    private static let dotDiameter: CGFloat = 9

    override init() {
        super.init()
        let side = Self.side
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let pink = SeamPalette.colors[0]

        let pulse = CAShapeLayer()
        pulse.frame = bounds
        pulse.path = CGPath(ellipseIn: CGRect(x: side / 2 - 7, y: side / 2 - 7, width: 14, height: 14), transform: nil)
        pulse.fillColor = nil
        pulse.strokeColor = pink.cgColor
        pulse.lineWidth = 1.5
        addSublayer(pulse)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6; scale.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9; fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(group, forKey: "pulse")

        let dot = CAShapeLayer()
        dot.frame = bounds
        let d = Self.dotDiameter
        dot.path = CGPath(ellipseIn: CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d), transform: nil)
        dot.fillColor = pink.cgColor
        dot.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.lineWidth = 1
        dot.shadowColor = pink.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 5
        dot.shadowOffset = .zero
        addSublayer(dot)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
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
        // One transform per pass: the bar is laid out at final size (vector-crisp) and
        // frame-placed through the same `chromeViewRect` as the granny viewer; the
        // footer tracks the settled bar; the ghost mouse's size rides the same scale.
        if let myT, myT.scale > 0 {
            let k = chromeTileScale(myT)
            restyleBar(scale: k)
            layoutBar(in: myT)
            layoutFooter(scale: k)
            if let arrow = ghostArrow {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                arrow.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
                CATransaction.commit()
            }
        }
        for t in ghostGlassViews { t.setGhost(inactive) }
        for t in ghostTintTargets { t.setGhost(inactive) }
        // `syncButtons` runs before this and may have read a stale `isGhost`; re-apply.
        applyStateIconGhostTint()
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

    /// Position the footer under this canvas's own bar, font scaled with it (native text
    /// at the target point size — crisp, not a layer-scaled bitmap).
    private func layoutFooter(scale s: CGFloat) {
        guard let bar = barContainer else { return }
        footerLabel.font = .systemFont(ofSize: (11 * s).rounded())   // whole-point hints crispest
        footerLabel.sizeToFit()
        footerLabel.wantsLayer = true
        footerLabel.layer?.contentsScale = window?.backingScaleFactor ?? 2
        let size = footerLabel.frame.size
        footerLabel.setFrameOrigin(CGPoint(x: pixelSnap(bar.frame.midX - size.width / 2),
                                           y: pixelSnap(bar.frame.minY - 8 * s - size.height)))
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
    /// or nil. Called on the active canvas to decide what every canvas shows.
    func hoveredTooltip(at activePoint: CGPoint) -> String? {
        for control in tooltipControls where control.isEnabled {
            let f = control.convert(control.bounds, to: self)
            if f.contains(activePoint), let tip = tooltipText(for: control) { return tip }
        }
        return nil
    }

    /// The fun copy per control — the single source (native `.toolTip` is cleared; it
    /// would pop on the hovered screen only, doubling up).
    private func tooltipText(for control: NSControl) -> String? {
        switch control {
        case feedButton:  return state.feedEnabled ? Copy.feedOnTooltip : Copy.feedOffTooltip
        case resetButton: return Copy.resetTooltip
        case undoButton:  return Copy.undoTooltip
        case resSlider:   return Copy.sliderTooltip
        case scopeButton: return state.sliderScope == .all ? Copy.scopeAllTooltip : Copy.scopeOneTooltip
        case doneButton:  return Copy.doneTooltip
        default:          return nil
        }
    }

    /// Show/hide this canvas's tooltip bubble at the ghost-mapped cursor. Both nil ⇒ hide.
    func updateTooltip(text: String?, cursorActivePoint: CGPoint?) {
        guard let text, let p = cursorActivePoint else { tooltipBubble?.isHidden = true; return }
        ensureTooltipBubble().show(text, at: ghostPoint(p), in: bounds)
    }

    private func ensureTooltipBubble() -> TooltipBubble {
        if let b = tooltipBubble { return b }
        let b = TooltipBubble(frame: .zero)
        addSubview(b)
        tooltipBubble = b
        return b
    }

    /// Move the beacon to the cursor's location on this canvas's schematic. Shows on
    /// every canvas; hidden if the host display has no tile.
    func updatePlaneMarker(cursor: CGPoint, hostID: CGDirectDisplayID?) {
        guard VirtualMouse.planeMarkerEnabled else { return }
        let marker = ensurePlaneMarker()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let p = beaconViewPoint(cursor: cursor, hostID: hostID) {
            marker.position = p
            marker.isHidden = false
        } else {
            marker.isHidden = true
        }
        CATransaction.commit()
    }

    /// Cursor → fraction of the host display's bounds → its plane rect → this canvas's
    /// transform. A mirrored display maps through its master; no plane rect ⇒ nil.
    private func beaconViewPoint(cursor: CGPoint, hostID: CGDirectDisplayID?) -> CGPoint? {
        guard let hostID, let t = drawTransform(currentRects()) else { return nil }
        let planeID = plane[hostID] != nil
            ? hostID
            : displays.first(where: { $0.id == hostID })?.mirrorMaster ?? hostID
        guard let planeRect = plane[planeID],
              let pp = ArrangerGeometry.planePoint(cursor: cursor,
                                                   displayBounds: CGDisplayBounds(hostID),
                                                   planeRect: planeRect) else { return nil }
        return t.viewPoint(pp)
    }

    private func ensurePlaneMarker() -> PlaneMouseMarkerLayer {
        if let m = planeMarkerLayer { return m }
        wantsLayer = true
        let m = PlaneMouseMarkerLayer()
        m.zPosition = 4          // above particles (1), glow (2), panel (3); below arrow (6)
        layer?.addSublayer(m)
        planeMarkerLayer = m
        return m
    }
}
