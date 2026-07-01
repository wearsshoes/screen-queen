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
/// (true relative sizes). A pure namespace of conversions, shared by the arranger
/// (`ArrangementCanvas`) and the on-glass overlay so the two never disagree.
///
/// The two directions are `toPlane` (point → physical, to interpret a committed
/// layout) and `toPoints` (physical → point, to commit the plane). The seam map
/// between them is *continuous*: a display's coordinate along a seam is a smooth
/// (piecewise-linear) function through the four anchor points where the metric
/// spaces must agree — the two corners and the two edge-alignments.
enum SchematicLayout {

    /// Physical size in inches, falling back to a points/100 proxy when the
    /// physical size is unknown (so unsized displays still lay out sensibly).
    static func physSize(_ d: DisplaySnapshot) -> CGSize {
        let w = d.physicalSizeMM.width / 25.4, h = d.physicalSizeMM.height / 25.4
        if w > 1, h > 1 { return CGSize(width: w, height: h) }
        return CGSize(width: d.bounds.width / 100, height: d.bounds.height / 100)
    }

    // MARK: - Interpret: point → physical (the plane)

    /// Lay the committed point arrangement out on the physical plane: a BFS from
    /// the main display docks each display to its parent and places it along the
    /// seam via the seam map.
    static func toPlane(_ eff: [DisplaySnapshot]) -> [CGDirectDisplayID: CGRect] {
        guard !eff.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: eff.map { ($0.id, $0) })
        let start = eff.first(where: { $0.isMain }) ?? eff[0]
        var out: [CGDirectDisplayID: CGRect] = [start.id: CGRect(origin: .zero, size: physSize(start))]
        var queue = [start.id]
        let tol: CGFloat = 2

        while !queue.isEmpty {
            let parent = byID[queue.removeFirst()]!
            let pp = parent.bounds          // point bounds
            let pr = out[parent.id]!        // physical rect
            for child in eff where out[child.id] == nil {
                let c = child.bounds, cs = physSize(child)
                // Allow touching-or-overlapping (incl. corner adjacency, overlap ≈ 0)
                // so diagonal pairs connect and place via the blended map.
                let yOv = min(pp.maxY, c.maxY) - max(pp.minY, c.minY)
                let xOv = min(pp.maxX, c.maxX) - max(pp.minX, c.minX)
                var r: CGRect?
                if abs(c.minX - pp.maxX) <= tol, yOv > -tol {
                    r = CGRect(x: pr.maxX, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.maxX - pp.minX) <= tol, yOv > -tol {
                    r = CGRect(x: pr.minX - cs.width, y: alignedPerp(child: child, parent: parent, pr, cs, vertical: true), width: cs.width, height: cs.height)
                } else if abs(c.minY - pp.maxY) <= tol, xOv > -tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.maxY, width: cs.width, height: cs.height)
                } else if abs(c.maxY - pp.minY) <= tol, xOv > -tol {
                    r = CGRect(x: alignedPerp(child: child, parent: parent, pr, cs, vertical: false), y: pr.minY - cs.height, width: cs.width, height: cs.height)
                }
                if let r { out[child.id] = r; queue.append(child.id) }
            }
        }
        // Fallback for displays with no shared edge at all: place relative to the
        // main at the main's density (keeps the point relationship at a consistent
        // scale rather than an arbitrary points/100 spot).
        if eff.contains(where: { out[$0.id] == nil }) {
            let mr = out[start.id]!
            let kx = mr.width / start.bounds.width, ky = mr.height / start.bounds.height
            for d in eff where out[d.id] == nil {
                out[d.id] = CGRect(x: mr.minX + (d.bounds.minX - start.bounds.minX) * kx,
                                   y: mr.minY + (d.bounds.minY - start.bounds.minY) * ky,
                                   width: physSize(d).width, height: physSize(d).height)
            }
        }
        return out
    }

    // MARK: - Commit: physical → point

    /// Inverse of `toPlane`: given the physical plane `rects` (and each display's
    /// point size via `displays`), reconstruct a point arrangement. BFS from the
    /// main; each child docked to a placed parent gets its perpendicular
    /// point-flush and its along-seam point via the inverse seam map. The main
    /// lands at (0,0) (the commit pins it there anyway).
    static func toPoints(rects: [CGDirectDisplayID: CGRect],
                         displays: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        guard !displays.isEmpty else { return [:] }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let start = displays.first(where: { $0.isMain }) ?? displays[0]
        guard rects[start.id] != nil else {
            return Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.bounds.origin) })
        }
        var origins: [CGDirectDisplayID: CGPoint] = [start.id: .zero]
        var queue = [start.id]
        let tol: CGFloat = 2

        while !queue.isEmpty {
            let parent = byID[queue.removeFirst()]!
            let pr = rects[parent.id]!                                   // parent physical
            let pp = CGRect(origin: origins[parent.id]!, size: parent.bounds.size) // parent point
            for child in displays where origins[child.id] == nil {
                guard let cr = rects[child.id] else { continue }
                let cs = child.bounds.size, cPhys = physSize(child)
                let yOv = min(pr.maxY, cr.maxY) - max(pr.minY, cr.minY)
                let xOv = min(pr.maxX, cr.maxX) - max(pr.minX, cr.minX)
                func along(_ physAlong: CGFloat, _ vertical: Bool) -> CGFloat {
                    seamPoint(physAlong, seamAnchors(child: child, cPhys, parentPoint: pp, parentPhys: pr, vertical: vertical))
                }
                var origin: CGPoint?
                if abs(cr.minX - pr.maxX) <= tol, yOv > -tol {
                    origin = CGPoint(x: pp.maxX, y: along(cr.minY, true))
                } else if abs(cr.maxX - pr.minX) <= tol, yOv > -tol {
                    origin = CGPoint(x: pp.minX - cs.width, y: along(cr.minY, true))
                } else if abs(cr.minY - pr.maxY) <= tol, xOv > -tol {
                    origin = CGPoint(x: along(cr.minX, false), y: pp.maxY)
                } else if abs(cr.maxY - pr.minY) <= tol, xOv > -tol {
                    origin = CGPoint(x: along(cr.minX, false), y: pp.minY - cs.height)
                }
                if let origin { origins[child.id] = origin; queue.append(child.id) }
            }
        }
        // Disconnected (e.g. Shift-dragged into a gap): place relative to the main
        // at the main's density — the inverse of the toPlane fallback.
        if let mr = rects[start.id] {
            let kx = start.bounds.width / max(mr.width, 0.01), ky = start.bounds.height / max(mr.height, 0.01)
            for d in displays where origins[d.id] == nil {
                let dr = rects[d.id] ?? CGRect(origin: .zero, size: physSize(d))
                origins[d.id] = CGPoint(x: (dr.minX - mr.minX) * kx, y: (dr.minY - mr.minY) * ky)
            }
        }
        return origins
    }

    /// The child's physical coordinate along the seam, as a *piecewise-linear* map
    /// through four anchor points where the two metric spaces must agree: the two
    /// corners (child's far edge at parent's near edge) and the two edge-alignments
    /// (point-left↔physical-left, point-right↔physical-right). So point anchors
    /// render at physical anchors (left/center/right flush, corner at corner),
    /// sizes stay physical, and the slope differs per region (the smaller screen's
    /// density on the outer legs; the difference density across the middle, which
    /// goes vertical when the point widths match).
    private static func alignedPerp(child: DisplaySnapshot, parent: DisplaySnapshot,
                                    _ pr: CGRect, _ cs: CGSize, vertical: Bool) -> CGFloat {
        let anchors = seamAnchors(child: child, cs, parentPoint: parent.bounds, parentPhys: pr, vertical: vertical)
        return seamPhysical(vertical ? child.bounds.minY : child.bounds.minX, anchors)
    }

    /// Point-along → physical-along along a seam, via the four seam anchors (both
    /// edge-alignments always kept, so edges render flush even when a screen is
    /// taller-and-narrower than its neighbor and the map is non-monotonic — that's
    /// fine here: interpret and commit only evaluate it *at* anchors, where it's
    /// exact, and the drag never touches it).
    static func seamPhysical(_ pointAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        piecewise(pointAlong, anchors)
    }

    /// The inverse (physical-along → point-along) used at commit.
    static func seamPoint(_ physAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        piecewise(physAlong, anchors.map { ($0.1, $0.0) })
    }

    /// The four (point, physical) anchor pairs along the seam where the two metric
    /// spaces must agree — two corners and the two edge-alignments. The forward map
    /// (alignedPerp) interpolates point→physical through these; the drag inverts
    /// physical→point by swapping the pairs.
    static func seamAnchors(child: DisplaySnapshot, _ cs: CGSize,
                            parentPoint pp: CGRect, parentPhys pr: CGRect,
                            vertical: Bool) -> [(CGFloat, CGFloat)] {
        let c = child.bounds
        return vertical
            ? [(pp.minY - c.height, pr.minY - cs.height), (pp.minY, pr.minY),
               (pp.maxY - c.height, pr.maxY - cs.height), (pp.maxY, pr.maxY)]
            : [(pp.minX - c.width, pr.minX - cs.width), (pp.minX, pr.minX),
               (pp.maxX - c.width, pr.maxX - cs.width), (pp.maxX, pr.maxX)]
    }

    /// Linear interpolation through `pts` (x → y), extrapolating with the end
    /// slopes outside the range. Ties in x (collapsed anchors) read as a jump.
    static func piecewise(_ x: CGFloat, _ pts: [(CGFloat, CGFloat)]) -> CGFloat {
        let p = pts.sorted { $0.0 < $1.0 }
        func lerp(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat {
            guard b.0 != a.0 else { return (a.1 + b.1) / 2 } // vertical segment → midpoint
            return a.1 + (b.1 - a.1) / (b.0 - a.0) * (x - a.0)
        }
        if x <= p[0].0 { return lerp(p[0], p[1]) }
        for i in 0..<(p.count - 1) where x <= p[i + 1].0 { return lerp(p[i], p[i + 1]) }
        return lerp(p[p.count - 2], p[p.count - 1])
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

    static func frac(_ a: HAnchor) -> CGFloat { a == .left ? 0 : (a == .center ? 0.5 : 1) }
    static func frac(_ a: VAnchor) -> CGFloat { a == .top ? 0 : (a == .center ? 0.5 : 1) }

    /// The seven *physical* alignment positions along a horizontal seam: the
    /// child's `minX` that puts each of the child's physical anchors onto the
    /// parent's matching physical anchor. Sorted by position (visual order) for
    /// cycling and used as the drag magnet targets. `parent` is the parent's plane
    /// rect (inches).
    static func physSnapsH(childWidth cw: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: HAnchor, otherAnchor: HAnchor)] {
        hPairs.map { (pr.minX + frac($0.1) * pr.width - frac($0.0) * cw, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    static func physSnapsV(childHeight ch: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: VAnchor, otherAnchor: VAnchor)] {
        vPairs.map { (pr.minY + frac($0.1) * pr.height - frac($0.0) * ch, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Reference bars

    static func seamBars(_ displays: [DisplaySnapshot],
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
