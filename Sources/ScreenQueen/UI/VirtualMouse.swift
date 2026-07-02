import AppKit

/// The two mouse aids for the "one of the girls went dark" scenario. If a bad mode
/// blacks out a screen, the arranger is still running there (it's on every screen),
/// but the user can't see their cursor. These make it findable from any live screen:
///
/// - **The beacon** (`planeMarkerEnabled`): a pulsing map pin on every canvas's
///   schematic marking where the real mouse is *within the arrangement*, so you can
///   watch yourself steer it across a seam to safety.
/// - **The understudy** (`ghostCursorEnabled`): on every canvas that *doesn't* hold
///   the real mouse, a ghost arrow at the equivalent canvas-relative position — she
///   mirrors the lead's blocking, so you can see what the invisible cursor is
///   pointing at (the same controls exist on every canvas).
///
/// Each is deliberately styled as *not the real cursor* — a pin and a dashed ghost,
/// never an opaque arrow. Flip either flag to bench that girl; they're independent.
enum VirtualMouse {
    /// Feature flag: the beacon (map pin on the schematic, all canvases).
    static let planeMarkerEnabled = true
    /// Feature flag: the understudy (ghost cursor on cursor-less canvases).
    static let ghostCursorEnabled = true

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
}

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

// MARK: - Per-canvas placement

extension Arranger {

    /// Reposition both mouse aids for a new global cursor sample. Called by
    /// `ArrangerWindows` on every mouse move — layer moves only, never a canvas
    /// redraw. `cursor` is in global CG coords (top-left origin, the
    /// `CGDisplayBounds` convention); `host` is the canvas on the display under the
    /// cursor (nil if that display has no overlay) and `hostPoint` the cursor in the
    /// host's y-up view coords.
    func updateMouseOverlays(cursor: CGPoint, hostID: CGDirectDisplayID?,
                             host: Arranger?, hostPoint: CGPoint?) {
        ensureMouseLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let marker = planeMarkerLayer {
            if let p = beaconViewPoint(cursor: cursor, hostID: hostID) {
                marker.isHidden = false
                marker.position = p
            } else {
                marker.isHidden = true
            }
        }
        if let ghost = ghostCursorLayer {
            if let host, host !== self, let hostPoint,
               let p = ghostViewPoint(host: host, hostPoint: hostPoint) {
                ghost.isHidden = false
                ghost.position = p
            } else {
                ghost.isHidden = true   // the real cursor is here (or nowhere we know)
            }
        }
    }

    /// The beacon's view position: cursor → display fraction → plane → this canvas's
    /// transform. A mirrored slave maps through her master's plane rect; a display
    /// with no plane rect at all (AirPlay card, unknown) hides the pin.
    private func beaconViewPoint(cursor: CGPoint, hostID: CGDirectDisplayID?) -> CGPoint? {
        guard let hostID, let t = transform(currentRects()) else { return nil }
        let planeID = plane[hostID] != nil
            ? hostID
            : displays.first(where: { $0.id == hostID })?.mirrorMaster ?? hostID
        guard let planeRect = plane[planeID],
              let pp = VirtualMouse.planePoint(cursor: cursor,
                                               displayBounds: CGDisplayBounds(hostID),
                                               planeRect: planeRect) else { return nil }
        return t.viewPoint(pp)
    }

    /// The understudy's view position on this canvas for a cursor at `hostPoint` on
    /// `host`. Zone-based: positions over per-canvas chrome map control-for-control
    /// (same offset within the twin chrome here); everything else rides the shared
    /// physical plane through both transforms.
    private func ghostViewPoint(host: Arranger, hostPoint: CGPoint) -> CGPoint? {
        // The button bar: identical on every canvas, so an absolute offset from the
        // container's origin lands on the very same control.
        if let hostBar = host.barContainer, hostBar.frame.contains(hostPoint), let myBar = barContainer {
            return CGPoint(x: myBar.frame.minX + (hostPoint.x - hostBar.frame.minX),
                           y: myBar.frame.minY + (hostPoint.y - hostBar.frame.minY))
        }
        // The "what she sees" panel: each canvas's panel is independently draggable,
        // so map relative to each one's own frame.
        let hostPanel = host.solvePanel
        if hostPanel.frame.contains(hostPoint) {
            let myPanel = solvePanel
            return CGPoint(x: myPanel.frame.minX + (hostPoint.x - hostPanel.frame.minX),
                           y: myPanel.frame.minY + (hostPoint.y - hostPanel.frame.minY))
        }
        // Anywhere else: through the shared plane (the schematic is the same layout on
        // every canvas). Clamped so an extrapolated background point can't wander off
        // a smaller canvas — a ghost pinned at the edge still tells the story.
        guard let hostT = host.transform(host.currentRects()),
              let myT = transform(currentRects()) else { return nil }
        let p = myT.viewPoint(hostT.planePoint(hostPoint))
        let r = bounds.insetBy(dx: 8, dy: 8)
        guard !r.isEmpty else { return nil }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX),
                       y: min(max(p.y, r.minY), r.maxY))
    }

    /// Build the enabled overlay layers once, above every schematic layer (seam
    /// particles 1, front glow 2, SolvePanel 3).
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
            let l = GhostCursorLayer()
            l.zPosition = 5
            l.isHidden = true
            layer?.addSublayer(l)
            ghostCursorLayer = l
        }
    }
}
