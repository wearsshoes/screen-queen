import QuartzCore

// The beacon: a pulsing map-pin at the cursor's location on the *schematic*, shown on
// every stage — where you are on the map, from any screen. A map marker, not a
// pointer: distinct from the ghost mouse (VirtualMouse.swift), which mirrors the
// cursor itself. Toggled by `Prefs.beacon`.

/// A hot-pink dot with a repeating expanding pulse ring (Find-My style).
final class PlaneMouseMarkerLayer: CALayer {

    private static let side: CGFloat = 44
    private static let dotDiameter: CGFloat = 9

    override init() {
        super.init()
        let side = Self.side
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let pink = SeamPalette.pinkCG

        let pulse = CAShapeLayer()
        pulse.frame = bounds
        pulse.path = CGPath(ellipseIn: CGRect(x: side / 2 - 7, y: side / 2 - 7, width: 14, height: 14), transform: nil)
        pulse.fillColor = nil
        pulse.strokeColor = pink
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
        dot.fillColor = pink
        dot.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
        dot.lineWidth = 1
        dot.shadowColor = pink
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 5
        dot.shadowOffset = .zero
        addSublayer(dot)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

extension Stage {

    /// Move the beacon to the cursor's location on this stage's schematic. Shows on
    /// every stage; hidden if the host display has no tile.
    func updatePlaneMarker(cursor: CGPoint, hostID: CGDirectDisplayID?) {
        guard Prefs.beacon else { return }
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

    /// Cursor → fraction of the host display's bounds → its plane rect → this stage's
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
