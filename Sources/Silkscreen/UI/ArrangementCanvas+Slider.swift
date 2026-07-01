import AppKit

/// A small `A ●———— a` resolution slider drawn on the selected tile: a discoverable
/// stand-in for the ⌘±/0 shortcut. Following macOS ("Larger Text" ↔ "More Space"),
/// the left "A" end = larger UI / lower resolution and the right "a" end = more
/// space / higher resolution — so dragging *right* raises the resolution. Dragging
/// previews live and commits on release, exactly like the keyboard path.
extension ArrangementCanvas {

    /// Height of the band the slider reserves within the centered label stack (track
    /// plus room for the knob/glyphs above and below the line).
    var resSliderBandHeight: CGFloat { 18 }

    /// The slider's track rect within `tile`, centered on `centerY` (view coords), or
    /// nil if the tile is too small to host it. Inset for the A/a end glyphs.
    func resSliderTrack(in tile: NSRect, centerY: CGFloat) -> NSRect? {
        guard tile.width >= 96, tile.height >= 64 else { return nil }
        let sideInset: CGFloat = 24          // clears the A/a end glyphs
        let w = tile.width - sideInset * 2
        guard w >= 44 else { return nil }
        return NSRect(x: tile.minX + sideInset, y: centerY - resSliderTrackThickness / 2,
                      width: w, height: resSliderTrackThickness)
    }

    private var resSliderTrackThickness: CGFloat { 4 }
    private var resSliderKnobRadius: CGFloat { 7 }

    /// The knob center for a normalized position `t` (0…1) along `track`.
    func resSliderKnob(_ track: NSRect, at t: CGFloat) -> CGPoint {
        CGPoint(x: track.minX + track.width * max(0, min(1, t)), y: track.midY)
    }

    /// Current normalized knob position for `d` (0 = left "A" = lowest res; 1 = right
    /// "a" = highest res), or nil when the display has fewer than two selectable modes.
    func resSliderPosition(for d: DisplaySnapshot) -> CGFloat? {
        let modes = sortedModes(for: d)
        guard modes.count > 1 else { return nil }
        guard let idx = currentModeIndex(for: d, in: modes) else { return 0.5 }
        // sortedModes is small→large point area (low→high res), matching left→right.
        return CGFloat(idx) / CGFloat(modes.count - 1)
    }

    /// Hit radius around the track for grabbing.
    var resSliderGrabInset: CGFloat { 12 }

    /// Whether `p` (view coords) is on the selected tile's slider, and if so the track.
    /// Uses the track from the most recent draw, whose Y is set by the label layout.
    func resSliderHit(at p: CGPoint) -> (id: CGDirectDisplayID, track: NSRect, display: DisplaySnapshot)? {
        guard let id = selectedID,
              let d = displays.first(where: { $0.id == id }),
              let track = state.lastSliderTrack, state.lastSliderTrackID == id else { return nil }
        let zone = track.insetBy(dx: -resSliderGrabInset, dy: -resSliderGrabInset)
        return zone.contains(p) ? (id, track, d) : nil
    }

    /// Map a view x onto `d`'s mode along `track` (left = low res, right = high res),
    /// returning the target mode.
    func resSliderMode(for d: DisplaySnapshot, track: NSRect, atX x: CGFloat) -> DisplayMode? {
        let modes = sortedModes(for: d)
        guard modes.count > 1 else { return modes.first }
        let t = max(0, min(1, (x - track.minX) / max(track.width, 1)))   // 0 left … 1 right
        let idx = Int((CGFloat(modes.count - 1) * t).rounded())          // left = low res
        return modes[max(0, min(modes.count - 1, idx))]
    }

    // MARK: - Drawing

    /// Draw the `A ●———— a` slider on `tile` for display `d`, centered on `centerY`
    /// (set by the label stack, so the slider sits between the name and the stats).
    /// Idiomatic macOS styling: a capsule track with a filled leading portion in the
    /// accent tint and a soft-shadowed round knob. Caches the track for hit-testing.
    func drawResSlider(for d: DisplaySnapshot, in tile: NSRect, centerY: CGFloat) {
        guard let pos = resSliderPosition(for: d),
              let track = resSliderTrack(in: tile, centerY: centerY) else { return }
        state.lastSliderTrack = track; state.lastSliderTrackID = d.id
        let ink = NSColor(white: 0.15, alpha: 1)            // dark, for the light selected tile
        let knob = resSliderKnob(track, at: pos)

        // Track: a rounded capsule. The leading (left, "A"-side) portion up to the knob
        // is filled with the accent to read as "amount", like a native slider.
        let radius = track.height / 2
        let base = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        ink.withAlphaComponent(0.22).setFill(); base.fill()

        let filled = NSRect(x: track.minX, y: track.minY, width: knob.x - track.minX, height: track.height)
        if filled.width > 0 {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }

        // End glyphs: large "A" left, small "a" right (a text-size metaphor for UI scale).
        let bigFont = NSFont.boldSystemFont(ofSize: 14)
        let smallFont = NSFont.systemFont(ofSize: 9)
        let attrs: (NSFont) -> [NSAttributedString.Key: Any] = {
            [.font: $0, .foregroundColor: ink.withAlphaComponent(0.6)]
        }
        let A = "A" as NSString, a = "a" as NSString
        let ASz = A.size(withAttributes: attrs(bigFont)), aSz = a.size(withAttributes: attrs(smallFont))
        A.draw(at: CGPoint(x: track.minX - ASz.width - 6, y: track.midY - ASz.height / 2), withAttributes: attrs(bigFont))
        a.draw(at: CGPoint(x: track.maxX + 6, y: track.midY - aSz.height / 2), withAttributes: attrs(smallFont))

        // Knob: white disc with a soft drop shadow and a hairline edge (native look).
        let r = resSliderKnobRadius
        let rect = NSRect(x: knob.x - r, y: knob.y - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)   // flipped view: +y is down
        shadow.shadowBlurRadius = 2.5
        shadow.set()
        let disc = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill(); disc.fill()
        NSGraphicsContext.restoreGraphicsState()
        ink.withAlphaComponent(0.18).setStroke(); disc.lineWidth = 0.5; disc.stroke()
    }
}
