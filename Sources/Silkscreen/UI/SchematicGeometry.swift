import AppKit

/// Pure schematic geometry — tiles and seams — solved entirely in **plane space**
/// (physical inches, the domain-native y-down arrangement from `CGDisplayBounds`).
///
/// This type deliberately knows nothing about the view, the `Transform`, or the y-up
/// flip: it emits plane-space primitives (rects and line segments), and the caller maps
/// them through the view transform *afterwards*. Keeping the geometry transform-free is
/// what lets the coordinate flip live in exactly one place (the `Transform`) instead of
/// being re-derived per shape.
enum SchematicGeometry {

    // MARK: - Tiles

    /// A tile is just its display's plane rect; the geometry here is its rounded-rect
    /// outline. `cornerRadius` is in the caller's target space (view px), so this is the
    /// one place a tile's *shape* (as opposed to its *position*) is defined.
    static func tilePath(_ rect: NSRect, cornerRadius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    }

    // MARK: - Seams

    /// A seam as a raw line segment in plane space: the two endpoints of the shared edge
    /// between two adjacent displays. `a`/`b` identify the pair (for coloring); the
    /// segment runs from `from` to `to` along the seam.
    struct SeamLine {
        let aID: CGDirectDisplayID
        let bID: CGDirectDisplayID
        let isVertical: Bool
        let from: CGPoint   // plane-space endpoint
        let to: CGPoint     // plane-space endpoint
    }

    /// Reduce each `SeamBar` to the bare seam segment in plane space — the line the two
    /// displays share, centered on the crossing region and spanning the smaller of the
    /// two physical crossing lengths (so the line sits within the actual shared edge).
    ///
    /// The bars/particles/labels are decoration layered on top of this line elsewhere;
    /// here we only solve where the seam *is*.
    static func seamLines(_ bars: [SeamBar]) -> [SeamLine] {
        bars.map { bar in
            // Span the crossing region: from the lower along-coordinate to the higher,
            // using the overlap common to both sides (min of the two physical lengths).
            let along = (bar.physAlongA + bar.physAlongB) / 2
            let half = min(bar.physLenInchesA, bar.physLenInchesB) / 2
            let lo = along - half, hi = along + half
            let from: CGPoint, to: CGPoint
            if bar.isVertical {
                // Vertical seam: constant x (the seam line), varying y.
                from = CGPoint(x: bar.physLine, y: lo)
                to   = CGPoint(x: bar.physLine, y: hi)
            } else {
                // Horizontal seam: constant y, varying x.
                from = CGPoint(x: lo, y: bar.physLine)
                to   = CGPoint(x: hi, y: bar.physLine)
            }
            return SeamLine(aID: bar.aID, bID: bar.bID, isVertical: bar.isVertical, from: from, to: to)
        }
    }
}
