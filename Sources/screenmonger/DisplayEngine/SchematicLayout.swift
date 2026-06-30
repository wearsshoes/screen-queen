import CoreGraphics

/// A reference bar at one seam, placed at the physically *smaller* screen's
/// center along the seam (clamped to the overlap). It carries the position in two
/// coordinate systems so the arranger and the on-glass overlay render the same
/// spot: physical (inch) coordinates for the mini-map, and the same location in
/// each display's global *point* coordinates for the glass.
///
/// The bar models a *window* 95% of the smaller screen's edge dragged across the
/// seam: one fixed **point** size (`windowPoints`) shown on both screens, capped
/// so it fits the overlap on each. Because a window keeps its point size across
/// displays, the two render at the same physical size only when the screens have
/// equal density; otherwise the physical lengths differ (`physLenInchesA/B`),
/// which is exactly the size change the bar is meant to reveal.
struct SeamBar {
    let aID: CGDirectDisplayID   // left (vertical seam) / top (horizontal seam)
    let bID: CGDirectDisplayID   // right / bottom
    let isVertical: Bool
    let physLine: CGFloat        // physical seam coordinate
    let physAlongA: CGFloat      // bar center along the seam on a (physical, clamped on-screen)
    let physAlongB: CGFloat      // ditto on b
    let pointAlongA: CGFloat     // bar center on a, in a's global point coords (clamped)
    let pointAlongB: CGFloat     // ditto on b
    let windowPoints: CGFloat    // the window's point size (same on both screens)
    let physLenInchesA: CGFloat  // that window's physical length on a
    let physLenInchesB: CGFloat  // ditto on b
}

/// Translation between the macOS *point* arrangement and the *physical* schematic
/// (true relative sizes). Built on demand from effective snapshots; shared by the
/// arranger (`ArrangementCanvas`) and the on-glass overlay (`OverlayController`)
/// so the two never disagree.
///
/// Alignment is *continuous*: a display's physical position is a smooth function
/// of its point origin (a BFS from the main display docks each display to its
/// parent and slides it along the seam at its own density). There is no discrete
/// "alignment intent" — the point offset is the alignment. Magnetic detents and
/// keyboard cycling target `horizontalSnaps`/`verticalSnaps`, the point offsets
/// that realize the seven *physical* anchor alignments (distinct even for
/// equal-point-width screens, since physical sizes differ).
struct SchematicLayout {
    let rects: [CGDirectDisplayID: CGRect]   // physical (inch) rects
    let bars: [SeamBar]
    /// BFS parent (the display each was docked to), main = root. Lets callers tell
    /// which of two adjacent displays is rendered as the child — its density is
    /// the one that governs the seam, so snap targets must use it.
    let parents: [CGDirectDisplayID: CGDirectDisplayID]

    init(displays: [DisplaySnapshot]) {
        let (rects, parents) = Self.physicalRects(displays)
        self.rects = rects
        self.parents = parents
        self.bars = Self.seamBars(displays, rects: rects)
    }

    /// Physical size in inches, falling back to a points/100 proxy when the
    /// physical size is unknown (so unsized displays still lay out sensibly).
    static func physSize(_ d: DisplaySnapshot) -> CGSize {
        let w = d.physicalSizeMM.width / 25.4, h = d.physicalSizeMM.height / 25.4
        if w > 1, h > 1 { return CGSize(width: w, height: h) }
        return CGSize(width: d.bounds.width / 100, height: d.bounds.height / 100)
    }

    // MARK: - Physical layout (BFS, continuous)

    private static func physicalRects(_ eff: [DisplaySnapshot])
        -> ([CGDirectDisplayID: CGRect], [CGDirectDisplayID: CGDirectDisplayID]) {
        guard !eff.isEmpty else { return ([:], [:]) }
        let byID = Dictionary(uniqueKeysWithValues: eff.map { ($0.id, $0) })
        let start = eff.first(where: { $0.isMain }) ?? eff[0]
        var out: [CGDirectDisplayID: CGRect] = [start.id: CGRect(origin: .zero, size: physSize(start))]
        var parents: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        var queue = [start.id]
        let tol: CGFloat = 2

        while !queue.isEmpty {
            let parent = byID[queue.removeFirst()]!
            let pp = parent.bounds          // point bounds
            let pr = out[parent.id]!        // physical rect
            for child in eff where out[child.id] == nil {
                let c = child.bounds, cs = physSize(child)
                let yOv = min(pp.maxY, c.maxY) - max(pp.minY, c.minY)
                let xOv = min(pp.maxX, c.maxX) - max(pp.minX, c.minX)
                var r: CGRect?
                if abs(c.minX - pp.maxX) <= tol, yOv > tol {
                    r = CGRect(x: pr.maxX, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.maxX - pp.minX) <= tol, yOv > tol {
                    r = CGRect(x: pr.minX - cs.width, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.minY - pp.maxY) <= tol, xOv > tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.maxY, width: cs.width, height: cs.height)
                } else if abs(c.maxY - pp.minY) <= tol, xOv > tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.minY - cs.height, width: cs.width, height: cs.height)
                }
                if let r { out[child.id] = r; parents[child.id] = parent.id; queue.append(child.id) }
            }
        }
        // Disconnected fallback (e.g. corner-only / diagonal arrangements with no
        // edge overlap): place relative to the main at the main's density, so the
        // point-space relationship is preserved at a consistent physical scale
        // instead of jumping to an arbitrary points/100 spot.
        if eff.contains(where: { out[$0.id] == nil }) {
            let mr = out[start.id]!
            let kx = mr.width / start.bounds.width, ky = mr.height / start.bounds.height
            for d in eff where out[d.id] == nil {
                out[d.id] = CGRect(x: mr.minX + (d.bounds.minX - start.bounds.minX) * kx,
                                   y: mr.minY + (d.bounds.minY - start.bounds.minY) * ky,
                                   width: physSize(d).width, height: physSize(d).height)
            }
        }
        return (out, parents)
    }

    /// The child's physical perpendicular coordinate (minY for a vertical seam,
    /// minX for horizontal): the parent's edge plus the child's point offset
    /// scaled at the *child's own* density. Continuous, and it lands exactly on a
    /// physical anchor when the point origin is one of the `*Snaps` values — so
    /// the schematic moves smoothly as the displays slide, with no special cases.
    private static func alignedPerp(child: DisplaySnapshot, parent: DisplaySnapshot,
                                    _ pr: CGRect, _ cs: CGSize, vertical: Bool) -> CGFloat {
        if vertical {
            return pr.minY + (child.bounds.minY - parent.bounds.minY) * (cs.height / child.bounds.height)
        } else {
            return pr.minX + (child.bounds.minX - parent.bounds.minX) * (cs.width / child.bounds.width)
        }
    }

    // MARK: - Physical snap targets (the seven anchor offsets)

    /// The seven alignment configs per seam, in spatial order (the selected
    /// display sliding from one extreme to the other along the shared edge).
    /// Index 3 is center↔center; (left,right)/(right,left) are intentionally
    /// absent (they'd pull the displays apart).
    static let hPairs: [(HAnchor, HAnchor)] = [
        (.center, .left), (.left, .left), (.right, .center), (.center, .center),
        (.left, .center), (.right, .right), (.center, .right)
    ]
    static let vPairs: [(VAnchor, VAnchor)] = [
        (.center, .top), (.top, .top), (.bottom, .center), (.center, .center),
        (.top, .center), (.bottom, .bottom), (.center, .bottom)
    ]

    private static func frac(_ a: HAnchor) -> CGFloat { a == .left ? 0 : (a == .center ? 0.5 : 1) }
    private static func frac(_ a: VAnchor) -> CGFloat { a == .top ? 0 : (a == .center ? 0.5 : 1) }

    /// Target `minX` values for `sel` that put each physical anchor of `sel` onto
    /// the matching physical anchor of `other`, across a horizontal seam. Sorted
    /// by value (true physical order) for monotonic cycling.
    ///
    /// The seam is rendered using the *child's* density (the BFS descendant), so
    /// the offset must be computed with that density — otherwise the alignment
    /// drifts by the screens' density ratio (worse the more the PPIs differ).
    /// `selIsChild` says whether `sel` is that descendant.
    static func horizontalSnaps(sel: DisplaySnapshot, other: DisplaySnapshot,
                                selIsChild: Bool) -> [HSnap] {
        snaps(sel: sel, other: other, selIsChild: selIsChild,
              selMin: sel.bounds.minX, otherMin: other.bounds.minX,
              selPhys: physSize(sel).width, otherPhys: physSize(other).width,
              childPoints: (selIsChild ? sel : other).bounds.width,
              pairs: hPairs, frac: frac)
            .map { HSnap(value: $0.0, selfAnchor: $0.1, otherAnchor: $0.2, otherID: other.id) }
    }

    /// Target `minY` values for `sel` across a vertical seam (see `horizontalSnaps`).
    static func verticalSnaps(sel: DisplaySnapshot, other: DisplaySnapshot,
                              selIsChild: Bool) -> [VSnap] {
        snaps(sel: sel, other: other, selIsChild: selIsChild,
              selMin: sel.bounds.minY, otherMin: other.bounds.minY,
              selPhys: physSize(sel).height, otherPhys: physSize(other).height,
              childPoints: (selIsChild ? sel : other).bounds.height,
              pairs: vPairs, frac: frac)
            .map { VSnap(value: $0.0, selfAnchor: $0.1, otherAnchor: $0.2, otherID: other.id) }
    }

    /// Shared snap math: returns (sel target min, selfAnchor, otherAnchor) for the
    /// seven pairs. `Δ = childMin − parentMin` is computed at the child's density;
    /// `sel`'s target is then `otherMin ± Δ` depending on whether sel is child.
    private static func snaps<A>(sel: DisplaySnapshot, other: DisplaySnapshot, selIsChild: Bool,
                                 selMin: CGFloat, otherMin: CGFloat,
                                 selPhys: CGFloat, otherPhys: CGFloat, childPoints: CGFloat,
                                 pairs: [(A, A)], frac: (A) -> CGFloat) -> [(CGFloat, A, A)] {
        let cPhys = selIsChild ? selPhys : otherPhys
        let pPhys = selIsChild ? otherPhys : selPhys
        guard cPhys > 0 else { return [] }
        let k = childPoints / cPhys // points per inch on the child
        return pairs.map { selfA, otherA -> (CGFloat, A, A) in
            let cFrac = selIsChild ? frac(selfA) : frac(otherA)
            let pFrac = selIsChild ? frac(otherA) : frac(selfA)
            let delta = (pFrac * pPhys - cFrac * cPhys) * k // child.min − parent.min
            let value = selIsChild ? otherMin + delta : otherMin - delta
            return (value, selfA, otherA)
        }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Reference bars

    private static func seamBars(_ displays: [DisplaySnapshot],
                                 rects: [CGDirectDisplayID: CGRect]) -> [SeamBar] {
        let tol: CGFloat = 1.5
        var out: [SeamBar] = []
        for i in 0..<displays.count {
            for j in (i + 1)..<displays.count {
                guard let ri = rects[displays[i].id], let rj = rects[displays[j].id] else { continue }

                // Vertical seam: one display's right edge meets the other's left.
                if abs(ri.maxX - rj.minX) <= tol || abs(rj.maxX - ri.minX) <= tol {
                    let leftIsI = abs(ri.maxX - rj.minX) <= tol
                    let aI = leftIsI ? i : j, bI = leftIsI ? j : i
                    let A = rects[displays[aI].id]!, B = rects[displays[bI].id]!
                    let lo = max(A.minY, B.minY), hi = min(A.maxY, B.maxY)
                    if hi - lo > tol {
                        out.append(makeBar(displays, aI, bI, A, B, vertical: true,
                                           line: A.maxX, lo: lo, hi: hi))
                    }
                }
                // Horizontal seam: one display's bottom edge meets the other's top.
                if abs(ri.maxY - rj.minY) <= tol || abs(rj.maxY - ri.minY) <= tol {
                    let topIsI = abs(ri.maxY - rj.minY) <= tol
                    let aI = topIsI ? i : j, bI = topIsI ? j : i
                    let A = rects[displays[aI].id]!, B = rects[displays[bI].id]!
                    let lo = max(A.minX, B.minX), hi = min(A.maxX, B.maxX)
                    if hi - lo > tol {
                        out.append(makeBar(displays, aI, bI, A, B, vertical: false,
                                           line: A.maxY, lo: lo, hi: hi))
                    }
                }
            }
        }
        return out
    }

    private static func makeBar(_ displays: [DisplaySnapshot],
                                _ aI: Int, _ bI: Int, _ ra: CGRect, _ rb: CGRect,
                                vertical: Bool, line: CGFloat, lo: CGFloat, hi: CGFloat) -> SeamBar {
        let a = displays[aI], b = displays[bI]
        // Bar at the overlap center (a single absolute physical point shown on
        // both screens). While the screens are mostly aligned this is the smaller
        // screen's center; as they slide apart it stays centered in the overlap,
        // so relative to each screen the two bars drift opposite ways.
        let center = (lo + hi) / 2  // overlap center, the bar's ideal location
        // Points-per-inch along the seam axis (width for a horizontal seam).
        let aPPI = vertical ? a.bounds.height / max(ra.height, 0.01) : a.bounds.width / max(ra.width, 0.01)
        let bPPI = vertical ? b.bounds.height / max(rb.height, 0.01) : b.bounds.width / max(rb.width, 0.01)

        // The window = the full *smaller* screen's edge, as a POINT size (a window
        // keeps its point size when dragged across displays), capped to the point
        // overlap = the largest window that fits the shared edge. It then renders
        // at each screen's own density, so it's full on the smaller screen and
        // larger on a lower-PPI screen — the size change the bar reveals.
        let aPhys = vertical ? ra.height : ra.width
        let bPhys = vertical ? rb.height : rb.width
        let smallerPoints = aPhys <= bPhys ? (vertical ? a.bounds.height : a.bounds.width)
                                           : (vertical ? b.bounds.height : b.bounds.width)
        let pointOverlap = vertical
            ? min(a.bounds.maxY, b.bounds.maxY) - max(a.bounds.minY, b.bounds.minY)
            : min(a.bounds.maxX, b.bounds.maxX) - max(a.bounds.minX, b.bounds.minX)
        let windowPoints = max(0, min(smallerPoints, pointOverlap))
        let lenA = windowPoints / aPPI, lenB = windowPoints / bPPI // physical lengths

        // Keep each bar fully on its own screen (like a dragged window that stays
        // on-screen): clamp its center so the half-length doesn't cross the tile
        // edge. The wider, lower-PPI bar can push into the screen's non-overlapping
        // area but never off it.
        func clampAlong(_ r: CGRect, _ len: CGFloat) -> CGFloat {
            let lo = (vertical ? r.minY : r.minX) + len / 2
            let hi = (vertical ? r.maxY : r.maxX) - len / 2
            return lo <= hi ? min(max(center, lo), hi) : (lo + hi) / 2
        }
        let physAlongA = clampAlong(ra, lenA), physAlongB = clampAlong(rb, lenB)

        return SeamBar(
            aID: a.id, bID: b.id, isVertical: vertical,
            physLine: line, physAlongA: physAlongA, physAlongB: physAlongB,
            pointAlongA: pointCoord(physAlongA, physRect: ra, bounds: a.bounds, vertical: vertical),
            pointAlongB: pointCoord(physAlongB, physRect: rb, bounds: b.bounds, vertical: vertical),
            windowPoints: windowPoints,
            physLenInchesA: lenA, physLenInchesB: lenB
        )
    }

    /// Map a physical coordinate along the seam into a display's global *point*
    /// coordinate (physical and point are linearly related within one display).
    private static func pointCoord(_ phys: CGFloat, physRect: CGRect,
                                   bounds: CGRect, vertical: Bool) -> CGFloat {
        if vertical {
            guard physRect.height > 0 else { return bounds.midY }
            return bounds.minY + (phys - physRect.minY) / physRect.height * bounds.height
        } else {
            guard physRect.width > 0 else { return bounds.midX }
            return bounds.minX + (phys - physRect.minX) / physRect.width * bounds.width
        }
    }
}
