import AppKit

/// The mouse aids for the "one of the girls went dark" scenario — and, since v3,
/// the chrome-presence system that makes every screen's controls honestly usable
/// no matter where the (possibly invisible) cursor lives:
///
/// - **The beacon** (`planeMarkerEnabled`): a pulsing map pin on every canvas's
///   schematic marking where the real mouse is *within the arrangement*.
/// - **The understudy** (`ghostCursorEnabled`), three acts:
///   1. *Chrome presence*: chrome is laid out at identical anchor-space offsets on
///      every canvas (see `ArrangerState.uniformDockInset` & co.), and each screen's
///      chrome crossfades real ↔ ghost by the cursor's point-space proximity —
///      the cursor's screen wears it real, far screens wear the dashed ghost frame.
///      Buttons stay functional at any presence: blind clicks are the feature,
///      because every control acts on shared state (the twin of Done IS Done).
///   2. *The pink chrome*: on a cursor-less screen the controls wear the ghost
///      themselves — each button a pink outline and wash (`GhostElementLayer`),
///      fading in with the cursor's distance from this screen. No box around empty
///      space; the buttons *are* the ghost, and they sit exactly where the real
///      chrome sits, so it's the one indication that distance-matches the real.
///   3. *The ghost arrow* + *halo*: over the schematic, the cursor mirrored through
///      the plane (minimap) transform — one mapping, so it never snaps. Over a
///      control the arrow steps aside and that control's ghost lights up brighter
///      (`GhostHighlightLayer`, with a click flash) — "she's on Done," readable at
///      a glance.
///
/// Each aid is deliberately styled as *not the real cursor* — pins, dashes, halos,
/// never an opaque arrow. Flip either flag to bench that girl; they're independent.
enum VirtualMouse {
    /// Feature flag: the beacon (map pin on the schematic, all canvases).
    static let planeMarkerEnabled = true
    /// Feature flag: the understudy (ghost arrow + chrome presence + halos).
    static let ghostCursorEnabled = true

    /// Point-space distance over which a screen's chrome fades ghost → real as the
    /// cursor approaches (presence 0→1 across the last `presenceThreshold` points).
    static let presenceThreshold: CGFloat = 240

    /// Map a global cursor point onto the physical plane: its fraction within the
    /// display's point bounds transfers directly to the display's plane rect (both
    /// spaces are y-down, top-left origin — no flip here; the view flip happens in
    /// `Transform.viewPoint`). nil for degenerate bounds.
    static func planePoint(cursor: CGPoint, displayBounds: CGRect, planeRect: CGRect) -> CGPoint? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let fx = (cursor.x - displayBounds.minX) / displayBounds.width
        let fy = (cursor.y - displayBounds.minY) / displayBounds.height
        return CGPoint(x: planeRect.minX + fx * planeRect.width,
                       y: planeRect.minY + fy * planeRect.height)
    }

    /// How "here" a screen's chrome is for a cursor at `cursor` (global CG coords):
    /// 1 on the cursor's own screen, easing to 0 as the cursor's point-space distance
    /// to the screen's rect reaches `threshold`. Smooth by construction, so several
    /// screens can sit mid-fade during a crossing without any pops.
    static func presence(cursor: CGPoint, screenBounds: CGRect,
                         threshold: CGFloat = presenceThreshold) -> CGFloat {
        guard screenBounds.width > 0, screenBounds.height > 0, threshold > 0 else { return 0 }
        let dx = max(0, max(screenBounds.minX - cursor.x, cursor.x - screenBounds.maxX))
        let dy = max(0, max(screenBounds.minY - cursor.y, cursor.y - screenBounds.maxY))
        return smoothstep(1 - min(hypot(dx, dy) / threshold, 1))
    }

    /// The classic clamped ease-in-out.
    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

}

/// The six bar controls, by role — twin identity across canvases (every canvas has
/// the same bar, so `.done` here is `.done` everywhere).
enum BarControl: CaseIterable, Hashable { case feed, reset, undo, slider, scope, done }

/// A clickable the ghost can dock onto and halo across canvases. (The mirror-column
/// and AirPlay buttons aren't anchor-unified, so they're not targets — the arrow
/// just rides the plane mapping over them.)
enum GhostTarget: Hashable {
    case bar(BarControl)
    case banner(ArrangerState.CountdownKind, CountdownBanner.Role)
}

/// A single chrome control that wears the ghost itself (pink outline + wash), keyed
/// so its overlay layer persists frame to frame.
enum GhostElementKey: Hashable {
    case bar(BarControl)
    case banner(ArrangerState.CountdownKind, CountdownBanner.Role)
    case panel
}

// MARK: - Layers

/// The beacon: a hot-pink dot with a repeating expanding pulse ring (Find-My style).
/// Reads as a map pin, not a pointer — nobody should try to click with it.
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

/// The understudy: a dashed, glowing, see-through arrow silhouette in the palette's
/// hot pink. Obviously a ghost — the dashes and the translucent fill are the
/// costume; the glow is so she reads from across the room.
/// Its `position` is the arrow's *tip* (anchor at the top-left of the glyph).
final class GhostCursorLayer: CAShapeLayer {

    override init() {
        super.init()
        // The classic arrow outline, authored y-down (tip at 0,0) like cursor art,
        // flipped into this y-up layer while building the path.
        let art: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.5), CGPoint(x: 3.9, y: 12.8),
            CGPoint(x: 6.3, y: 18.4), CGPoint(x: 9.0, y: 17.2), CGPoint(x: 6.6, y: 11.6),
            CGPoint(x: 12.0, y: 11.6),
        ]
        let s: CGFloat = 1.35                       // a touch bigger than life — she projects
        let h: CGFloat = 18.4 * s
        let path = CGMutablePath()
        path.addLines(between: art.map { CGPoint(x: $0.x * s, y: h - $0.y * s) })
        path.closeSubpath()
        self.path = path
        bounds = CGRect(x: 0, y: 0, width: 12.0 * s, height: h)
        anchorPoint = CGPoint(x: 0, y: 1)           // the tip is the hotspot
        let pink = ArrangerState.seamPalette[0]     // the lead — she doesn't do subtle
        fillColor = pink.withAlphaComponent(0.35).cgColor
        strokeColor = pink.cgColor
        lineWidth = 2
        lineDashPattern = [4, 3]
        lineJoin = .round
        opacity = 0.95
        shadowColor = pink.cgColor                  // the glow that makes her legible
        shadowOpacity = 0.9
        shadowRadius = 6
        shadowOffset = .zero
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

/// The halo: a dashed hot-pink outline over the twin of the control the real cursor
/// is on — same costume as the arrow, so they read as one act.
final class GhostHighlightLayer: CAShapeLayer {

    override init() {
        super.init()
        let pink = ArrangerState.seamPalette[0]
        fillColor = pink.withAlphaComponent(0.10).cgColor
        strokeColor = pink.cgColor
        lineWidth = 2
        lineDashPattern = [4, 3]
        shadowColor = pink.cgColor
        shadowOpacity = 0.8
        shadowRadius = 5
        shadowOffset = .zero
        isHidden = true
    }

    /// Fit the halo around `rect` (view coords), capsule-cornered.
    func show(over rect: CGRect) {
        let r = rect.insetBy(dx: -3, dy: -3)
        frame = r
        let radius = min(r.height / 2, 28)
        path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
        isHidden = false
    }

    /// A brief brighten when the control is actually clicked — the act, made visible.
    func flash() {
        guard !isHidden else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 2.0   // >1 clamps: reads as a pop without a second layer
        a.toValue = 1.0
        a.duration = 0.3
        add(a, forKey: "flash")
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

/// A chrome control's own ghost: a pink outline and translucent wash laid right over
/// the real button, fading in with the cursor's distance. The buttons *are* the
/// ghost — no bounding box around empty space.
final class GhostElementLayer: CAShapeLayer {

    override init() {
        super.init()
        let pink = ArrangerState.seamPalette[0]
        fillColor = pink.withAlphaComponent(0.22).cgColor
        strokeColor = pink.cgColor
        lineWidth = 2
        shadowColor = pink.cgColor
        shadowOpacity = 0.7
        shadowRadius = 5
        shadowOffset = .zero
        isHidden = true
    }

    /// Lay the ghost over `rect` (view coords); `strength` 0 hides it (chrome fully
    /// real — the cursor's own screen).
    func update(around rect: CGRect, radius: CGFloat, strength: CGFloat) {
        guard strength > 0.02, !rect.isEmpty else { isHidden = true; return }
        frame = rect
        let radius = min(radius, rect.height / 2)
        path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
        opacity = Float(min(1, strength))
        isHidden = false
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Per-canvas placement

extension Arranger {

    /// Reposition every mouse aid for a new global cursor sample. Called by
    /// `ArrangerWindows` on every mouse event — layer moves only, never a canvas
    /// redraw. `cursor` is in global CG coords (top-left origin); `host` is the
    /// canvas on the display under the cursor (nil if that display has no overlay),
    /// `hostPoint` the cursor in the host's y-up view coords, and `target` the
    /// control the cursor is on (frozen by ArrangerWindows for a press-drag's
    /// duration — "outside of a drag action" gating lives there).
    ///
    /// Two indications, no snapping: this screen's own chrome wears the ghost
    /// (`applyChromePresence`, distance-driven, where the real chrome sits), and the
    /// arrow rides the ONE plane (minimap) transform over the schematic — stepping
    /// aside over a control so its ghost can light up instead.
    func updateMouseOverlays(cursor: CGPoint, hostID: CGDirectDisplayID?,
                             host: Arranger?, hostPoint: CGPoint?, target: GhostTarget?) {
        ensureMouseLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if VirtualMouse.ghostCursorEnabled { applyChromePresence(cursor: cursor) }

        if let marker = planeMarkerLayer {
            if let p = beaconViewPoint(cursor: cursor, hostID: hostID) {
                marker.isHidden = false
                marker.position = p
            } else {
                marker.isHidden = true
            }
        }
        guard let ghost = ghostCursorLayer else { return }
        guard let host, host !== self, let hostPoint else {
            // The real cursor is here (or nowhere we know): the lead is on stage.
            ghost.isHidden = true
            ghostHighlightLayer?.isHidden = true
            return
        }
        if let target, let myRect = rect(of: target) {
            // The cursor's on a control: light up THIS screen's own ghost of it (the
            // one that sits where the real control sits) brighter, and step the arrow
            // aside — over chrome the pink buttons carry the story, not a pointer.
            ghost.isHidden = true
            ghostHighlightLayer?.show(over: myRect)
        } else {
            ghostHighlightLayer?.isHidden = true
            if let p = ghostViewPoint(host: host, hostPoint: hostPoint) {
                ghost.isHidden = false
                ghost.position = p
            } else {
                ghost.isHidden = true
            }
        }
    }

    /// This screen's chrome wears the ghost itself: each control gets a pink outline
    /// and wash that fades in as the cursor leaves this screen (presence → 0). The
    /// buttons *are* the ghost — no box around empty space — and they sit where the
    /// real chrome sits, so this is the indication that distance-matches the real.
    private func applyChromePresence(cursor: CGPoint) {
        guard let id = centerID else { return }
        let strength = 1 - VirtualMouse.presence(cursor: cursor, screenBounds: CGDisplayBounds(id))
        var live: Set<GhostElementKey> = []
        func paint(_ key: GhostElementKey, _ rect: CGRect, radius: CGFloat) {
            ghostElement(key).update(around: rect, radius: radius, strength: strength)
            live.insert(key)
        }
        if strength > 0.02 {
            for (control, view) in barCapsules {
                let r = view.convert(view.bounds, to: self)
                paint(.bar(control), r, radius: r.height / 2)
            }
            if let banner, !banner.isHidden {
                for kind in ArrangerState.CountdownKind.allCases {
                    for role in [CountdownBanner.Role.keep, .act] {
                        if let r = banner.buttonRect(kind: kind, role: role) {
                            paint(.banner(kind, role), banner.convert(r, to: self), radius: 8)
                        }
                    }
                }
            }
            if !solvePanel.isHidden { paint(.panel, solvePanel.frame, radius: 6) }
        }
        for (key, layer) in ghostElementLayers where !live.contains(key) { layer.isHidden = true }
    }

    private func ghostElement(_ key: GhostElementKey) -> GhostElementLayer {
        if let layer = ghostElementLayers[key] { return layer }
        let layer = GhostElementLayer()
        layer.zPosition = 5
        self.layer?.addSublayer(layer)
        ghostElementLayers[key] = layer
        return layer
    }

    /// Flash this canvas's halo (the press-echo; ArrangerWindows calls it on the
    /// non-host canvases when a targeted control is actually clicked).
    func flashGhostHighlight() { ghostHighlightLayer?.flash() }

    // MARK: Targets (host-side hit-test + twin lookup)

    /// The control under `p` on THIS canvas, if any (skipping disabled ones — a dead
    /// Undo gives no ghost feedback, mirroring the real hover).
    func ghostTarget(at p: CGPoint) -> GhostTarget? {
        guard VirtualMouse.ghostCursorEnabled else { return nil }
        for (control, view) in barCapsules {
            guard isTargetEnabled(control) else { continue }
            if view.convert(view.bounds, to: self).contains(p) { return .bar(control) }
        }
        if let banner, !banner.isHidden {
            for kind in ArrangerState.CountdownKind.allCases {
                for role in [CountdownBanner.Role.keep, .act] {
                    if let r = banner.buttonRect(kind: kind, role: role),
                       banner.convert(r, to: self).contains(p) { return .banner(kind, role) }
                }
            }
        }
        return nil
    }

    /// The twin's rect on THIS canvas, view coords (layout is anchor-identical, so
    /// this is the same lookup the host did).
    func rect(of target: GhostTarget) -> CGRect? {
        switch target {
        case .bar(let control):
            guard let view = barCapsules[control] else { return nil }
            return view.convert(view.bounds, to: self)
        case .banner(let kind, let role):
            guard let banner, !banner.isHidden, let r = banner.buttonRect(kind: kind, role: role)
            else { return nil }
            return banner.convert(r, to: self)
        }
    }

    private func isTargetEnabled(_ control: BarControl) -> Bool {
        switch control {
        case .undo: return undoButton.isEnabled
        case .slider: return resSlider.isEnabled
        default: return true
        }
    }

    // MARK: Placement math

    /// The beacon's view position: cursor → display fraction → plane → this canvas's
    /// (drag-frozen) transform. A mirrored slave maps through her master's plane
    /// rect; a display with no plane rect at all (AirPlay card, unknown) hides the pin.
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

    /// The understudy's position on this canvas for a cursor at `hostPoint` on
    /// `host`: the shared plane transform, everywhere — the schematic is the same
    /// layout on every canvas, and the host's chrome is *projected* through the same
    /// transform (see `updateProjectedChrome`), so there are no zones and nothing to
    /// snap between. Clamped so an extrapolated background point can't wander off a
    /// smaller canvas.
    private func ghostViewPoint(host: Arranger, hostPoint: CGPoint) -> CGPoint? {
        guard let hostT = host.drawTransform(host.currentRects()),
              let myT = drawTransform(currentRects()) else { return nil }
        let p = myT.viewPoint(hostT.planePoint(hostPoint))
        let r = bounds.insetBy(dx: 8, dy: 8)
        guard !r.isEmpty else { return nil }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }

    /// Build the enabled overlay layers once, above every schematic layer (seam
    /// particles 1, front glow 2, SolvePanel 3): beacon 4, frames/halo 5, arrow 6.
    private func ensureMouseLayers() {
        wantsLayer = true
        if VirtualMouse.planeMarkerEnabled, planeMarkerLayer == nil {
            let l = PlaneMouseMarkerLayer()
            l.zPosition = 4
            l.isHidden = true
            layer?.addSublayer(l)
            planeMarkerLayer = l
        }
        if VirtualMouse.ghostCursorEnabled, ghostCursorLayer == nil {
            let halo = GhostHighlightLayer()
            halo.zPosition = 5
            layer?.addSublayer(halo)
            ghostHighlightLayer = halo
            let l = GhostCursorLayer()
            l.zPosition = 6
            l.isHidden = true
            layer?.addSublayer(l)
            ghostCursorLayer = l
        }
    }
}
