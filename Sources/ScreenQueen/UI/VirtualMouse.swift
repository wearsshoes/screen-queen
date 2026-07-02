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
///   2. *The ghost arrow*: on cursor-less canvases, docked on the twin control when
///      the cursor is on one (same fraction — a slider scrub mirrors live), riding
///      the anchor translation over chrome gaps, and mirroring the shared schematic
///      everywhere else (so you can rearrange while watching any screen).
///   3. *The halo* (`GhostHighlightLayer`): the twin control under the cursor lights
///      up on every other canvas — "she's on Done over there," readable at a glance.
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

    /// Fraction-preserving dock: where `hostPoint` sits within `hostRect`, transferred
    /// to `destRect`. This is what makes the mirrored arrow ride the twin slider at
    /// the same position along it.
    static func dockedPoint(hostPoint: CGPoint, hostRect: CGRect, destRect: CGRect) -> CGPoint {
        let fx = hostRect.width > 0 ? (hostPoint.x - hostRect.minX) / hostRect.width : 0.5
        let fy = hostRect.height > 0 ? (hostPoint.y - hostRect.minY) / hostRect.height : 0.5
        return CGPoint(x: destRect.minX + fx * destRect.width,
                       y: destRect.minY + fy * destRect.height)
    }

    // Anchor-space translations between canvases of different sizes. Chrome sits at
    // identical anchor offsets everywhere (2a), so these are exact — no frames needed.

    /// Bottom-center anchored (the button bar): x re-centered, y unchanged.
    static func bottomCenterMapped(_ p: CGPoint, hostSize: CGSize, destSize: CGSize) -> CGPoint {
        CGPoint(x: p.x + (destSize.width - hostSize.width) / 2, y: p.y)
    }
    /// Top-center anchored (the countdown banner): x re-centered, distance-from-top kept.
    static func topCenterMapped(_ p: CGPoint, hostSize: CGSize, destSize: CGSize) -> CGPoint {
        CGPoint(x: p.x + (destSize.width - hostSize.width) / 2,
                y: destSize.height - (hostSize.height - p.y))
    }
    // Bottom-left anchored (the solve panel): identity — no mapper needed.
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

/// The chrome pieces that carry presence (alpha + ghost frame).
enum ChromePiece: Hashable { case bar, banner, panel }

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

/// The ghost frame: a dashed outline around a whole chrome piece whose presence has
/// faded — "these controls work, but the cursor isn't here."
final class GhostFrameLayer: CAShapeLayer {

    override init() {
        super.init()
        let pink = ArrangerState.seamPalette[0]
        fillColor = nil
        strokeColor = pink.cgColor
        lineWidth = 1.5
        lineDashPattern = [5, 4]
        isHidden = true
    }

    /// Wrap `rect` (view coords); `strength` 0 hides it (fully "real" chrome).
    func update(around rect: CGRect, radius: CGFloat, strength: CGFloat) {
        guard strength > 0.02, !rect.isEmpty else { isHidden = true; return }
        let r = rect.insetBy(dx: -4, dy: -4)
        frame = r
        path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size),
                      cornerWidth: min(radius, r.height / 2), cornerHeight: min(radius, r.height / 2),
                      transform: nil)
        opacity = Float(strength * 0.9)
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
        if let target, let myRect = rect(of: target), let hostRect = host.rect(of: target) {
            // On a control: halo the twin and dock the arrow at the same fraction.
            ghost.isHidden = false
            ghost.position = VirtualMouse.dockedPoint(hostPoint: hostPoint, hostRect: hostRect,
                                                      destRect: myRect)
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

    // MARK: Presence

    /// Crossfade this canvas's chrome real ↔ ghost by cursor proximity (see
    /// `VirtualMouse.presence`). Alpha carries the fade; the dashed ghost frame
    /// carries the costume. Controls stay clickable at any presence.
    private func applyChromePresence(cursor: CGPoint) {
        guard let id = centerID else { return }
        let presence = VirtualMouse.presence(cursor: cursor, screenBounds: CGDisplayBounds(id))
        let alpha = 0.45 + 0.55 * presence
        let strength = 1 - presence
        if let bar = barContainer {
            bar.alphaValue = alpha
            ghostFrame(.bar).update(around: bar.frame, radius: bar.frame.height / 2, strength: strength)
        }
        if let banner, !banner.isHidden {
            banner.alphaValue = alpha
            ghostFrame(.banner).update(around: banner.frame, radius: 18, strength: strength)
        } else {
            ghostFrames[.banner]?.isHidden = true
        }
        if !solvePanel.isHidden {
            solvePanel.alphaValue = alpha
            ghostFrame(.panel).update(around: solvePanel.frame, radius: 6, strength: strength)
        } else {
            ghostFrames[.panel]?.isHidden = true
        }
    }

    private func ghostFrame(_ piece: ChromePiece) -> GhostFrameLayer {
        if let layer = ghostFrames[piece] { return layer }
        let layer = GhostFrameLayer()
        layer.zPosition = 5
        self.layer?.addSublayer(layer)
        ghostFrames[piece] = layer
        return layer
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

    /// The understudy's off-target position on this canvas for a cursor at
    /// `hostPoint` on `host`. Chrome zones map by pure anchor translation (the
    /// chrome sits at identical anchor offsets everywhere — 2a); everything else
    /// rides the shared physical plane through both (drag-frozen) transforms.
    private func ghostViewPoint(host: Arranger, hostPoint: CGPoint) -> CGPoint? {
        if let hostBar = host.barContainer, hostBar.frame.contains(hostPoint) {
            return VirtualMouse.bottomCenterMapped(hostPoint, hostSize: host.bounds.size,
                                                   destSize: bounds.size)
        }
        if let hostBanner = host.banner, !hostBanner.isHidden, hostBanner.frame.contains(hostPoint) {
            return VirtualMouse.topCenterMapped(hostPoint, hostSize: host.bounds.size,
                                                destSize: bounds.size)
        }
        if !host.solvePanel.isHidden, host.solvePanel.frame.contains(hostPoint) {
            return hostPoint   // bottom-left anchored: same coords by construction
        }
        // The schematic (and anything unmapped): through the shared plane — the same
        // layout on every canvas, so a blind drag mirrors exactly. Clamped so an
        // extrapolated background point can't wander off a smaller canvas.
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
