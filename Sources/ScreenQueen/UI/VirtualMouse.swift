import AppKit

/// The ghost of the *active* screen (the one under the cursor), shown on every other
/// screen. There is only ONE set of chrome per canvas — no parallel ghost structure.
/// Based on whether this display is active, that one chrome:
///
/// - **active**: sits in its normal place, its normal look.
/// - **inactive**: the *same* controls, each restyled pink *in its own look*
///   (`GhostTintable`) — pink glass, pink slider track, pink-outlined panel — and
///   transformed to the active screen's perspective on this canvas's minimap (free to
///   run off-screen). No flat overlay; the tint is worked into every element.
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

    /// The one ghost tint, worked into each element's own styling. Hot pink from the
    /// seam palette — the same color the ghost mouse wears.
    static var pink: NSColor { ArrangerState.seamPalette[0] }

    /// The minimap scale (view px per physical inch of the schematic) at which the chrome
    /// renders at its natural, unscaled size. The bar, ghost mouse, and granny viewer all
    /// scale by `transform.scale / this` (`Arranger.chromeTileScale`), so they grow/shrink
    /// together with the tiles. This one number sets their absolute size at a normal zoom —
    /// raise it to shrink everything, lower it to grow.
    static let referenceMinimapScale: CGFloat = 40

    /// Feature flag: the beacon (pulsing map-pin on the schematic, every canvas).
    static let planeMarkerEnabled = true

    /// Map a global cursor point onto the physical plane: its fraction within the
    /// display's point bounds transfers directly to the display's plane rect (both spaces
    /// are y-down, top-left origin — no flip here; the view flip happens in
    /// `Transform.viewPoint`). nil for degenerate bounds.
    static func planePoint(cursor: CGPoint, displayBounds: CGRect, planeRect: CGRect) -> CGPoint? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let fx = (cursor.x - displayBounds.minX) / displayBounds.width
        let fy = (cursor.y - displayBounds.minY) / displayBounds.height
        return CGPoint(x: planeRect.minX + fx * planeRect.width,
                       y: planeRect.minY + fy * planeRect.height)
    }
}

/// The beacon: a hot-pink dot with a repeating expanding pulse ring (Find-My style).
/// Reads as a map pin, not a pointer — it marks where the cursor is on the *schematic*,
/// on every canvas, so you can find yourself on the map from any screen.
final class PlaneMouseMarkerLayer: CALayer {

    private static let side: CGFloat = 44
    private static let dotDiameter: CGFloat = 9

    override init() {
        super.init()
        let side = Self.side
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let pink = ArrangerState.seamPalette[0]

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

/// A chrome element that knows how to wear the ghost tint *in its own look* — a pink
/// glass capsule, a pink slider track, a pink-outlined panel — rather than hiding under
/// a flat overlay. `setGhost(true)` is applied on inactive displays, `false` restores.
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
        isGhost = inactive   // so syncButtons tints rebuilt icons to match this mode
        if inactive,
           let myT = drawTransform(currentRects()),
           let actT = active!.drawTransform(active!.currentRects()), actT.scale > 0 {
            // The ghost is drawn as if it were part of the minimap: as different between
            // the screens as their *tiles* are. So `ghostScale` is the ratio of the two
            // canvases' minimap scales (view px per physical inch of the schematic) —
            // this canvas's ÷ the active canvas's. Both the ghost's size and its offset
            // from centre ride it, so a button that's beside a tile on the active screen
            // is beside the matching (differently-sized) tile here.
            ghostScale = myT.scale / actT.scale
            ghostActiveCenter = CGPoint(x: active!.bounds.midX, y: active!.bounds.midY)
        } else {
            ghostScale = 1
            ghostActiveCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // The button bar is *laid out* at this canvas's own tile scale (`restyleBar`), so
        // it renders vector-crisp — no bitmap upscale. Its transform is then a pure
        // *translation* to position it (identity when active; the ghost-mapped spot when
        // inactive). `ghostScale · active.chromeTileScale == this.chromeTileScale`, so the
        // ghost bar's laid-out size already matches; only its position needs mapping.
        restyleBar(scale: chromeTileScale)
        if let bar = barContainer { positionBar(bar, active: active, inactive: inactive) }
        // The banner still rides the scaling transform (it's not laid out per-scale).
        for (view, activeView) in chromeViewPairs(active: active) where view !== barContainer {
            applyChromeTransform(view, activeCounterpart: activeView, active: active, inactive: inactive)
        }
        // The footer line rides the *bar's* transform (scaled about the bar's centre), so it
        // stays glued just below the bar as the bar grows/shrinks with the zoom — the two
        // move as one instead of the footer being recomputed elsewhere.
        applyFooterTransform(active: active, inactive: inactive)
        // The tint lives in each element's own styling, not a flat overlay.
        for t in ghostGlassViews { t.setGhost(inactive) }
        for t in ghostTintTargets { t.setGhost(inactive) }
        // The feed and scope icons are tinted from state in `syncButtons`, which runs
        // *before* this (so it reads a stale `isGhost` right after an active-screen
        // change). Re-apply them here now that `isGhost` is fresh, else the pink/black
        // shows inverted for a beat on the screen that just switched.
        applyStateIconGhostTint()
        // The granny panel is plane-anchored — it already sits on the same tile corner
        // and scales with the minimap on every canvas, so it takes no ghost transform
        // (any leftover is cleared); only the pink tint marks it as the ghost.
        solvePanel.layer?.setAffineTransform(.identity)
        solvePanel.setGhost(inactive)
    }

    /// Scale that sizes the button bar in proportion to *this* canvas's minimap tiles, so
    /// the chrome reads as part of the schematic: bigger tiles → bigger bar. It's the
    /// minimap scale (view px per physical inch of the schematic) over a reference, so the
    /// bar is its natural size at a typical zoom and grows/shrinks with the tiles. 1 if the
    /// transform isn't ready. The ghost composes cleanly: `ghostScale · active.chromeTileScale`
    /// = this canvas's own `chromeTileScale`, so active and ghost bars match their tiles.
    var chromeTileScale: CGFloat {
        guard let t = drawTransform(currentRects()), t.scale > 0 else { return 1 }
        return t.scale / VirtualMouse.referenceMinimapScale
    }

    /// Map a point from the active canvas's view coords onto this canvas — the ghost
    /// transform shared by the mouse and the chrome. `ghostScale` (this canvas's minimap
    /// scale ÷ the active's) turns the point's offset from the active centre into this
    /// canvas's — so a point beside the active tile lands beside the matching (differently
    /// sized) tile here, the same way the tiles themselves differ. Identity when active.
    func ghostPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.midX + ghostScale * (p.x - ghostActiveCenter.x),
                y: bounds.midY + ghostScale * (p.y - ghostActiveCenter.y))
    }

    /// The one set of chrome, paired with its twin on the active canvas: the button bar,
    /// the granny panel, and the countdown banner when it's up. The active twin's frame
    /// is what we map onto this canvas so the ghost sits where the real chrome sits over
    /// there. Adding a UI element = add its pairing here.
    private func chromeViewPairs(active: Arranger?) -> [(NSView, NSView?)] {
        var pairs: [(NSView, NSView?)] = []
        if let bar = barContainer { pairs.append((bar, active?.barContainer)) }
        if let banner, !banner.isHidden { pairs.append((banner, active?.banner)) }
        return pairs
    }

    /// Position the (already correctly-*sized*, via `restyleBar`) button bar with a pure
    /// translation — no scale, so nothing is blurred. Active: identity (the bar's own
    /// constraints centre it). Inactive: shift its centre to the ghost-mapped spot of the
    /// active bar, snapped to the pixel grid.
    private func positionBar(_ bar: NSView, active: Arranger?, inactive: Bool) {
        bar.wantsLayer = true
        guard let layer = bar.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard inactive, let active, let twin = active.barContainer else {
            layer.setAffineTransform(.identity); return
        }
        let target = ghostPoint(CGPoint(x: twin.frame.midX, y: twin.frame.midY))
        let vc = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
        layer.setAffineTransform(CGAffineTransform(translationX: pixelSnap(target.x - vc.x),
                                                   y: pixelSnap(target.y - vc.y)))
    }

    /// Transform one chrome view for the mode:
    ///
    /// - **active / no twin**: scale by this screen's `chromeTileScale` about the view's
    ///   own centre — the bar is sized to this canvas's tiles, staying put (centre fixed).
    /// - **inactive**: the active twin, at the active screen's tile size
    ///   (`active.chromeTileScale`), mapped onto this canvas by `ghostScale` — so the total
    ///   scale is `ghostScale · active.chromeTileScale` (= this canvas's own `chromeTileScale`)
    ///   and the centre lands at `ghostPoint(twin centre)`, under the ghost mouse, sized to
    ///   this canvas's tiles just like the real bar over there is sized to the active's.
    ///
    /// A CALayer scales about its **anchor point** (not reliably the centre for a
    /// layer-backed NSView — AppKit often uses (0, 0)). We derive the anchor's location
    /// `a` in this view's space and translate so the *scaled* view centre reaches the
    /// target, for any anchor.
    private func applyChromeTransform(_ view: NSView, activeCounterpart twin: NSView?,
                                      active: Arranger?, inactive: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let ap = layer.anchorPoint
        let a = CGPoint(x: view.frame.minX + ap.x * view.frame.width,
                        y: view.frame.minY + ap.y * view.frame.height)
        let vc = CGPoint(x: view.frame.midX, y: view.frame.midY)

        let s: CGFloat
        let target: CGPoint
        if inactive, let twin, let active {
            s = ghostScale * active.chromeTileScale
            target = ghostPoint(CGPoint(x: twin.frame.midX, y: twin.frame.midY))
        } else {
            s = chromeTileScale           // size to this canvas's tiles, in place
            target = vc
        }
        // Raise the render density *before* applying the transform, so the content is
        // re-rasterised for the enlarged size rather than the old bitmap being upscaled.
        sharpen(view, forScale: s)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Scaling by s about anchor a sends vc → a + s·(vc − a); translate to `target`.
        let landed = CGPoint(x: a.x + s * (vc.x - a.x), y: a.y + s * (vc.y - a.y))
        // Snap the translation to whole device pixels so the scaled bitmap lands on the
        // pixel grid — a fractional origin smears the icons/text across pixel boundaries.
        layer.setAffineTransform(CGAffineTransform(
            a: s, b: 0, c: 0, d: s,
            tx: pixelSnap(target.x - landed.x), ty: pixelSnap(target.y - landed.y)))
        CATransaction.commit()
    }

    /// Round a point value to the nearest whole *device* pixel (points × backing scale),
    /// so a transformed layer lands on the pixel grid instead of straddling it.
    func pixelSnap(_ v: CGFloat) -> CGFloat {
        let b = window?.backingScaleFactor ?? 2
        return (v * b).rounded() / b
    }

    /// Keep a layer-scaled view crisp. A layer transform scales the view's *rasterised*
    /// bitmap, so an enlarging scale (`s > 1`) blows up too-few pixels and blurs — worst on
    /// low-PPI displays where the tile scale runs largest. Render at the final on-screen
    /// density by lifting `contentsScale` to `backingScale · s` across the whole view+layer
    /// subtree (the glass's contentView → pad → button → icon image layer), so every piece
    /// draws enough pixels for the transformed size. Set *before* the transform is applied.
    private func sharpen(_ view: NSView, forScale s: CGFloat) {
        let backing = view.window?.backingScaleFactor ?? 2
        let scale = backing * max(1, s)   // only *raise* density; shrinking already supersamples
        func applyLayers(_ layer: CALayer) {
            if layer.contentsScale != scale { layer.contentsScale = scale }
            layer.sublayers?.forEach(applyLayers)
        }
        func applyViews(_ v: NSView) {
            v.wantsLayer = true
            if let l = v.layer { applyLayers(l) }
            v.needsDisplay = true          // re-render its own drawn content at the new density
            v.subviews.forEach(applyViews) // …and the whole subview tree (icons, glyphs, glass content)
        }
        applyViews(view)
    }

    /// Position the footer under the bar and size it to match — scaling the *font* (native,
    /// always crisp) rather than layer-scaling a rasterised label (which blurred on low-PPI
    /// displays where the tile scale runs large). It tracks the bar's *visual* bottom edge
    /// (the bar is layer-scaled about its centre), so it stays glued below the bar at any
    /// zoom. On a ghost canvas the bar's centre is the ghost-mapped one.
    private func applyFooterTransform(active: Arranger?, inactive: Bool) {
        guard let bar = barContainer else { return }
        let s: CGFloat
        let barCentre: CGPoint
        let barHeight: CGFloat
        if inactive, let active, let twin = active.barContainer {
            // The ghost bar mirrors the *active* canvas's bar, mapped by `ghostPoint` — so
            // the footer must follow the active bar's centre/height, not this canvas's own
            // (differently-sized) bar layout, exactly like `applyChromeTransform`.
            s = ghostScale * active.chromeTileScale
            barCentre = ghostPoint(CGPoint(x: twin.frame.midX, y: twin.frame.midY))
            barHeight = twin.frame.height
        } else {
            s = chromeTileScale
            barCentre = CGPoint(x: bar.frame.midX, y: bar.frame.midY)
            barHeight = bar.frame.height
        }
        // Whole-point font hints crispest; a fractional 15.07pt smears slightly.
        footerLabel.font = .systemFont(ofSize: (11 * s).rounded())
        footerLabel.sizeToFit()
        // Render the label's text at full backing density (belt-and-suspenders with the
        // grid snap — a stray sub-1× contentsScale would soften it).
        footerLabel.wantsLayer = true
        footerLabel.layer?.contentsScale = window?.backingScaleFactor ?? 2
        let barVisualBottom = barCentre.y - barHeight / 2 * s
        let size = footerLabel.frame.size
        // Snap the origin to whole device pixels so the text sits on the pixel grid
        // instead of straddling it.
        footerLabel.setFrameOrigin(CGPoint(x: pixelSnap(barCentre.x - size.width / 2),
                                           y: pixelSnap(barVisualBottom - 8 * s - size.height)))
    }

    /// Move the ghost mouse. `cursorActivePoint` is the real cursor in the active
    /// canvas's view coords; it rides the *same* scale-about-centre as the chrome (the
    /// active screen's centre to this canvas's centre). Hidden on the active screen.
    func updateGhostArrow(cursorActivePoint: CGPoint?, isActive: Bool) {
        guard VirtualMouse.ghostMouseEnabled else { return }
        let arrow = ensureGhostArrow()
        guard !isActive, let p = cursorActivePoint else { arrow.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arrow.position = ghostPoint(p)   // mirror of the cursor, sized to this canvas
        // The mouse, buttons, and granny viewer all ride the one `chromeTileScale`.
        let s = chromeTileScale
        arrow.setAffineTransform(CGAffineTransform(scaleX: s, y: s))
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

    /// The fun tooltip text for the bar control at `activePoint` (in the *active* canvas's
    /// view coords), or nil if the cursor isn't over a control with one. Called on the
    /// active canvas to decide what every canvas should show.
    func hoveredTooltip(at activePoint: CGPoint) -> String? {
        for control in tooltipControls where control.isEnabled {
            let f = control.convert(control.bounds, to: self)
            if f.contains(activePoint), let tip = tooltipText(for: control) { return tip }
        }
        return nil
    }

    /// The fun copy for a bar control — the feed and scope strings flip with state. This is
    /// the single source now (the native `.toolTip` is cleared so it can't double up on the
    /// hovered screen only).
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

    /// Show/hide this canvas's tooltip bubble. `text` is the hovered control's copy (from
    /// the active canvas's `hoveredTooltip`); `cursorActivePoint` is the cursor in the
    /// *active* canvas's coords. Both nil ⇒ hide. The cursor is mapped onto this canvas via
    /// the same `ghostPoint` the ghost mouse rides, so the bubble trails the (ghost) cursor
    /// on every screen at once.
    func updateTooltip(text: String?, cursorActivePoint: CGPoint?) {
        guard let text, let p = cursorActivePoint else { tooltipBubble?.isHidden = true; return }
        ensureTooltipBubble().show(text, at: ghostPoint(p), in: bounds)
    }

    private func ensureTooltipBubble() -> TooltipBubble {
        if let b = tooltipBubble { return b }
        let b = TooltipBubble(frame: .zero)
        addSubview(b)   // a real subview (draws text), above the chrome
        tooltipBubble = b
        return b
    }

    /// Move the beacon: the pulsing map-pin at the cursor's location on *this* canvas's
    /// schematic. `cursor` is the global cursor point; `hostID` the display it's on. Shows
    /// on every canvas (it's a map marker, not a pointer), hidden if the host has no tile.
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

    /// The beacon's view position on this canvas: cursor → its fraction of the host
    /// display's bounds → the host's plane rect → this canvas's transform. A mirrored
    /// display maps through its master's plane rect; a display with no plane rect (unknown,
    /// AirPlay) yields nil (hide the pin).
    private func beaconViewPoint(cursor: CGPoint, hostID: CGDirectDisplayID?) -> CGPoint? {
        guard let hostID, let t = drawTransform(currentRects()) else { return nil }
        let planeID = plane[hostID] != nil
            ? hostID
            : displays.first(where: { $0.id == hostID })?.mirrorMaster ?? hostID
        guard let planeRect = plane[planeID],
              let pp = VirtualMouse.planePoint(cursor: cursor,
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
