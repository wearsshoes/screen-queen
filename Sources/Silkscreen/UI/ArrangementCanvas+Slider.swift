import AppKit

/// A small `A ●———— a` resolution slider drawn on the selected tile: a discoverable
/// stand-in for the ⌘±/0 shortcut. Following macOS ("Larger Text" ↔ "More Space"),
/// the left "A" end = larger UI / lower resolution and the right "a" end = more
/// space / higher resolution — so dragging *right* raises the resolution. Dragging
/// previews live and commits on release, exactly like the keyboard path.
extension ArrangementCanvas {

    // The slider's *track* spans ~66% of the tile width; the knob, thickness, glyphs and
    // band all scale proportionally to that width (relative to a 160pt reference), so the
    // whole control grows/shrinks together with the tile — but independently of the label
    // text, which scales separately to preview resolution.
    private var resSliderTrackFraction: CGFloat { 0.40 }
    private var resSliderReferenceWidth: CGFloat { 160 }
    private func resSliderScale(trackWidth w: CGFloat) -> CGFloat { w / resSliderReferenceWidth }
    private func resSliderThickness(_ scale: CGFloat) -> CGFloat { 5 * scale }
    private func resSliderKnobRadius(_ scale: CGFloat) -> CGFloat { 9 * scale }

    /// Height of the band the slider reserves in the label stack, for a tile of `width`.
    func resSliderBandHeight(tileWidth: CGFloat) -> CGFloat {
        26 * resSliderScale(trackWidth: tileWidth * resSliderTrackFraction)
    }

    /// The slider's track rect within `tile`, centered on `centerY` (view coords), or
    /// nil if the tile is too small to host it. Track width ≈ 66% of the tile.
    func resSliderTrack(in tile: NSRect, centerY: CGFloat) -> NSRect? {
        guard tile.width >= 96, tile.height >= 64 else { return nil }
        let w = tile.width * resSliderTrackFraction
        guard w >= 44 else { return nil }
        let thickness = resSliderThickness(resSliderScale(trackWidth: w))
        return NSRect(x: tile.midX - w / 2, y: centerY - thickness / 2, width: w, height: thickness)
    }

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
              let track = lastSliderTrack, lastSliderTrackID == id else { return nil }
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
    func drawResSlider(for d: DisplaySnapshot, in tile: NSRect, centerY: CGFloat, tileColor: NSColor) {
        guard let pos = resSliderPosition(for: d),
              let track = resSliderTrack(in: tile, centerY: centerY) else { return }
        lastSliderTrack = track; lastSliderTrackID = d.id
        let scale = resSliderScale(trackWidth: track.width)
        let ink = NSColor(white: 0.15, alpha: 1)            // dark, for the light selected tile
        let knob = resSliderKnob(track, at: pos)

        // End glyphs: large "A" left, small "a" right — proportional to the track.
        let glyphGap = 7 * scale
        let bigFont = NSFont.boldSystemFont(ofSize: 16 * scale)
        let smallFont = NSFont.systemFont(ofSize: 10 * scale)
        let attrs: (NSFont) -> [NSAttributedString.Key: Any] = {
            [.font: $0, .foregroundColor: ink.withAlphaComponent(0.6)]
        }
        let A = "A" as NSString, a = "a" as NSString
        let ASz = A.size(withAttributes: attrs(bigFont)), aSz = a.size(withAttributes: attrs(smallFont))

        // The slider sits *on top* of the label text and must stay legible if the text
        // (which can zoom large) reaches it: paint an opaque tile-colored plate behind
        // the whole control first, masking anything underneath.
        let r = resSliderKnobRadius(scale)
        let plate = NSRect(x: track.minX - ASz.width - glyphGap * 2,
                           y: centerY - resSliderBandHeight(tileWidth: tile.width) / 2,
                           width: (track.maxX + aSz.width + glyphGap * 2) - (track.minX - ASz.width - glyphGap * 2),
                           height: resSliderBandHeight(tileWidth: tile.width))
        // A soft translucent white plate (matching the info plate / glass idiom), not an
        // opaque tile-colored slab — still masks the label text underneath.
        NSColor.white.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()

        // Track: a rounded capsule. The leading (left, "A"-side) portion up to the knob
        // is filled with a softened accent to read as "amount", like a native slider.
        let radius = track.height / 2
        let base = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        ink.withAlphaComponent(0.16).setFill(); base.fill()

        let filled = NSRect(x: track.minX, y: track.minY, width: knob.x - track.minX, height: track.height)
        if filled.width > 0 {
            (NSColor.controlAccentColor.blended(withFraction: 0.15, of: .white) ?? .controlAccentColor)
                .withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }

        A.draw(at: CGPoint(x: track.minX - ASz.width - glyphGap, y: track.midY - ASz.height / 2), withAttributes: attrs(bigFont))
        a.draw(at: CGPoint(x: track.maxX + glyphGap, y: track.midY - aSz.height / 2), withAttributes: attrs(smallFont))

        // Knob: white disc with a soft drop shadow and a hairline edge (native look).
        let rect = NSRect(x: knob.x - r, y: knob.y - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)   // flipped view: +y is down
        shadow.shadowBlurRadius = 2.5 * scale
        shadow.set()
        let disc = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill(); disc.fill()
        NSGraphicsContext.restoreGraphicsState()
        ink.withAlphaComponent(0.18).setStroke(); disc.lineWidth = 0.5; disc.stroke()
    }
}
