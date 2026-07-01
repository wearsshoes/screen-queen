import CoreGraphics

/// A reference bar at one seam: the stretch of the shared edge whose cursor-crossing
/// leads to the other display — i.e. the two screens' **point** overlap (what macOS
/// actually enforces), *not* their physical overlap, which differs by density. The
/// region is one point interval (`windowPoints`, same on both screens); it's physically
/// longer on the coarser screen (`physLenInchesA/B`).
struct SeamBar {
    let aID: CGDirectDisplayID   // left (vertical seam) / top (horizontal seam)
    let bID: CGDirectDisplayID   // right / bottom
    let isVertical: Bool
    let physLine: CGFloat        // physical seam coordinate
    let physAlongA: CGFloat      // region center along the seam on a (physical)
    let physAlongB: CGFloat      // ditto on b
    let localAlongA: CGFloat     // region center on a, as a point offset from a's leading edge
    let localAlongB: CGFloat     // ditto on b
    let windowPoints: CGFloat    // the crossing region's point length (same on both screens)
    let physLenInchesA: CGFloat  // that region's physical length on a
    let physLenInchesB: CGFloat  // ditto on b (longer on the coarser screen)
}

/// Translation between the macOS *point* arrangement and the *physical* schematic
/// (true relative sizes), shared by the arranger and the on-glass overlay.
///
/// `toPlane` interprets a committed layout (point → physical); `toPoints` converts
/// the plane back to commit (physical → point). A display's coordinate along a seam
/// maps piecewise-linearly through four anchors where the two metric spaces agree:
/// the two corners and the two edge-alignments.
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
        let byID = Dictionary(eff.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
                // Allow touching or corner-adjacent (overlap ≈ 0) so diagonal pairs connect.
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
        // Displays with no shared edge: place relative to the main at the main's density.
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

    /// Inverse of `toPlane`: reconstruct a point arrangement from the physical plane
    /// `rects` and each display's point size. BFS from the main; each child docked to
    /// a placed parent gets its perpendicular point-flush and its along-seam point via
    /// the inverse seam map. The main lands at (0,0).
    static func toPoints(rects: [CGDirectDisplayID: CGRect],
                         displays: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        guard !displays.isEmpty else { return [:] }
        let byID = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let start = displays.first(where: { $0.isMain }) ?? displays[0]
        guard rects[start.id] != nil else {
            return Dictionary(displays.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
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
                // The perpendicular flush is unambiguous; the *along-seam* inverse can be
                // (a child taller/wider than this parent has a non-monotonic seam map). So
                // resolve the along-coordinate against whichever *placed* neighbor gives an
                // unambiguous inverse — the seam set as a whole pins the one true preimage,
                // no exhaustive solve needed. Falls back to the parent's own (first) preimage.
                func along(_ physAlong: CGFloat, _ vertical: Bool) -> CGFloat {
                    resolveAlong(child: child, cPhys: cPhys, physAlong: physAlong,
                                 vertical: vertical, parent: parent, pp: pp, pr: pr,
                                 origins: origins, rects: rects, byID: byID)
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
        // at the main's density.
        if let mr = rects[start.id] {
            let kx = start.bounds.width / max(mr.width, 0.01), ky = start.bounds.height / max(mr.height, 0.01)
            for d in displays where origins[d.id] == nil {
                let dr = rects[d.id] ?? CGRect(origin: .zero, size: physSize(d))
                origins[d.id] = CGPoint(x: (dr.minX - mr.minX) * kx, y: (dr.minY - mr.minY) * ky)
            }
        }
        return origins
    }

    /// Resolve `child`'s point along-coordinate from its physical `physAlong`, using
    /// the seam set to disambiguate a non-monotonic inverse. Tries the docking parent
    /// first; if that seam has multiple preimages, walks the other *already-placed*
    /// neighbors sharing the same seam orientation for one that inverts unambiguously,
    /// and takes that. Falls back to the parent's first preimage when none is cleaner.
    private static func resolveAlong(child: DisplaySnapshot, cPhys: CGSize, physAlong: CGFloat,
                                     vertical: Bool, parent: DisplaySnapshot, pp: CGRect, pr: CGRect,
                                     origins: [CGDirectDisplayID: CGPoint],
                                     rects: [CGDirectDisplayID: CGRect],
                                     byID: [CGDirectDisplayID: DisplaySnapshot]) -> CGFloat {
        let cr = rects[child.id]!
        let base = seamPointResolved(physAlong, seamAnchors(child: child, cPhys, parentPoint: pp, parentPhys: pr, vertical: vertical))
        if base.preimages <= 1 { return base.point }   // parent seam already unique

        // Parent seam is ambiguous: find a placed neighbor whose seam (same orientation)
        // the child also shares, and whose inverse is unambiguous.
        let tol: CGFloat = 2
        for (nid, no) in origins where nid != parent.id {
            guard let n = byID[nid], let nr = rects[nid] else { continue }
            // Same-orientation seam with the child, on the physical plane?
            let shares = vertical
                ? (abs(cr.minX - nr.maxX) <= tol || abs(cr.maxX - nr.minX) <= tol)
                    && min(cr.maxY, nr.maxY) - max(cr.minY, nr.minY) > -tol
                : (abs(cr.minY - nr.maxY) <= tol || abs(cr.maxY - nr.minY) <= tol)
                    && min(cr.maxX, nr.maxX) - max(cr.minX, nr.minX) > -tol
            guard shares else { continue }
            let np = CGRect(origin: no, size: n.bounds.size)
            let r = seamPointResolved(physAlong, seamAnchors(child: child, cPhys, parentPoint: np, parentPhys: nr, vertical: vertical))
            if r.preimages == 1 { return r.point }
        }
        return base.point
    }

    /// The child's physical coordinate along the seam, from its point coordinate via
    /// the four seam anchors.
    private static func alignedPerp(child: DisplaySnapshot, parent: DisplaySnapshot,
                                    _ pr: CGRect, _ cs: CGSize, vertical: Bool) -> CGFloat {
        let anchors = seamAnchors(child: child, cs, parentPoint: parent.bounds, parentPhys: pr, vertical: vertical)
        return seamPhysical(vertical ? child.bounds.minY : child.bounds.minX, anchors)
    }

    /// Point-along → physical-along along a seam. The forward map is piecewise-linear
    /// in *point* order (the anchors' point coordinates are monotonic).
    static func seamPhysical(_ pointAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        piecewise(pointAlong, anchors)
    }

    /// The inverse (physical-along → point-along) used at commit, with how many seam
    /// segments the value could have come from — `preimages > 1` means this seam alone
    /// can't disambiguate (see `seamPoint`); a caller can then try another seam.
    ///
    /// The physical anchor coordinates can be *non-monotonic* (a child physically
    /// taller/wider than its parent puts the edge-alignment anchors outside the corner
    /// anchors), so we can't just swap and re-sort — sorting by physical scrambles which
    /// segment a value belongs to, and forward/inverse stop being inverses (a committed
    /// layout drifts). Instead invert segment-by-segment in the forward's own point
    /// order, so we land on the same segment the forward used.
    static func seamPointResolved(_ physAlong: CGFloat,
                                  _ anchors: [(CGFloat, CGFloat)]) -> (point: CGFloat, preimages: Int) {
        let p = anchors.sorted { $0.0 < $1.0 }   // forward order: by point coordinate
        func inv(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> CGFloat {
            guard b.1 != a.1 else { return (a.0 + b.0) / 2 }   // flat segment → point midpoint
            return a.0 + (b.0 - a.0) / (b.1 - a.1) * (physAlong - a.1)
        }
        // Each segment [p[i], p[i+1]] covers physical range [p[i].1, p[i+1].1] (either
        // orientation). Count the segments whose range contains `physAlong`; the first
        // is the answer (forward's own point order), the count is the ambiguity.
        var first: CGFloat?, count = 0
        for i in 0..<(p.count - 1) {
            let lo = min(p[i].1, p[i + 1].1), hi = max(p[i].1, p[i + 1].1)
            if physAlong >= lo, physAlong <= hi { count += 1; if first == nil { first = inv(p[i], p[i + 1]) } }
        }
        if let first { return (first, count) }
        // Outside all segments: extrapolate off whichever end is closer in physical.
        let firstMid = (p[0].1 + p[1].1) / 2
        let point = abs(physAlong - firstMid) <= abs(physAlong - (p[p.count - 2].1 + p[p.count - 1].1) / 2)
            ? inv(p[0], p[1]) : inv(p[p.count - 2], p[p.count - 1])
        return (point, 0)
    }

    /// The inverse (physical-along → point-along), taking the first (point-order)
    /// preimage. See `seamPointResolved` for the ambiguity count.
    static func seamPoint(_ physAlong: CGFloat, _ anchors: [(CGFloat, CGFloat)]) -> CGFloat {
        seamPointResolved(physAlong, anchors).point
    }

    /// The four (point, physical) anchor pairs along the seam where the two metric
    /// spaces agree — two corners and the two edge-alignments.
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

    /// The seven *physical* alignment positions along a horizontal seam: the child's
    /// `minX` that lands each child anchor on the parent's matching anchor, sorted by
    /// position (visual order) for cycling and drag-magnet targets.
    static func physSnapsH(childWidth cw: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: HAnchor, otherAnchor: HAnchor)] {
        hPairs.map { (pr.minX + frac($0.1) * pr.width - frac($0.0) * cw, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    static func physSnapsV(childHeight ch: CGFloat, parent pr: CGRect) -> [(along: CGFloat, selfAnchor: VAnchor, otherAnchor: VAnchor)] {
        vPairs.map { (pr.minY + frac($0.1) * pr.height - frac($0.0) * ch, $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Seam detection

    /// A shared edge between two rects `a` and `b` (global coords, CG y-down):
    /// its orientation and the overlapping interval `[lo, hi]` along it. `a` is the
    /// left/top rect, `b` the right/bottom. Used by both the arranger's reference
    /// bars and the calibration tool so they agree on where a seam is.
    struct Seam {
        let vertical: Bool     // true: a|b side by side; false: a stacked over b
        let line: CGFloat      // the seam coordinate (a.maxX or a.maxY)
        let lo: CGFloat, hi: CGFloat   // overlap interval along the seam

        /// The overlap center as an offset from `r`'s leading edge along the seam
        /// axis (its own local frame) — top for a vertical seam, left for a
        /// horizontal one. No global-origin arithmetic, so callers can place a bar
        /// on either screen without coordinate flips.
        func localCenter(on r: CGRect) -> CGFloat {
            let mid = (lo + hi) / 2
            return vertical ? mid - r.minY : mid - r.minX
        }
    }

    /// The seam shared by `a` and `b`, or nil if they aren't edge-adjacent.
    static func seam(_ a: CGRect, _ b: CGRect, tol: CGFloat = 2) -> Seam? {
        if abs(a.maxX - b.minX) <= tol || abs(b.maxX - a.minX) <= tol {
            let aLeft = abs(a.maxX - b.minX) <= tol
            let l = aLeft ? a : b, r = aLeft ? b : a
            let lo = max(l.minY, r.minY), hi = min(l.maxY, r.maxY)
            if hi - lo > tol { return Seam(vertical: true, line: l.maxX, lo: lo, hi: hi) }
        }
        if abs(a.maxY - b.minY) <= tol || abs(b.maxY - a.minY) <= tol {
            let aTop = abs(a.maxY - b.minY) <= tol
            let t = aTop ? a : b, bot = aTop ? b : a
            let lo = max(t.minX, bot.minX), hi = min(t.maxX, bot.maxX)
            if hi - lo > tol { return Seam(vertical: false, line: t.maxY, lo: lo, hi: hi) }
        }
        return nil
    }

    // MARK: - Reference bars

    static func seamBars(_ displays: [DisplaySnapshot],
                         rects: [CGDirectDisplayID: CGRect]) -> [SeamBar] {
        // A bar answers "if my cursor crosses here, what display do I land on?", so
        // adjacency is decided in *point* space (where the cursor lives), not on the
        // physical plane — two screens can be point-adjacent while their physical rects,
        // scaled by differing density, only corner-touch (or vice versa). Reconstruct
        // the point arrangement and find seams there.
        let origins = toPoints(rects: rects, displays: displays)
        func pointRect(_ d: DisplaySnapshot) -> CGRect {
            CGRect(origin: origins[d.id] ?? d.bounds.origin, size: d.bounds.size)
        }
        var out: [SeamBar] = []
        for i in 0..<displays.count {
            for j in (i + 1)..<displays.count {
                let pi = pointRect(displays[i]), pj = pointRect(displays[j])
                guard let s = seam(pi, pj) else { continue }
                // `seam` orders a = left/top; match i/j to that side.
                let iIsA = s.vertical ? abs(pi.maxX - s.line) < 1 : abs(pi.maxY - s.line) < 1
                let aI = iIsA ? i : j, bI = iIsA ? j : i
                // The mini-map draws on the physical plane, so it still needs the seam's
                // *physical* coordinate — the shared edge of the two physical rects.
                let ra = rects[displays[aI].id]!, rb = rects[displays[bI].id]!
                let physLine = s.vertical ? (ra.maxX + rb.minX) / 2 : (ra.maxY + rb.minY) / 2
                out.append(makeBar(displays, aI, bI, ra, rb,
                                   originA: origins[displays[aI].id], originB: origins[displays[bI].id],
                                   vertical: s.vertical, line: physLine))
            }
        }
        return out
    }

    private static func makeBar(_ displays: [DisplaySnapshot],
                                _ aI: Int, _ bI: Int, _ ra: CGRect, _ rb: CGRect,
                                originA: CGPoint?, originB: CGPoint?,
                                vertical: Bool, line: CGFloat) -> SeamBar {
        let a = displays[aI], b = displays[bI]
        // Inches-per-point along the seam axis (width for a horizontal seam), for the
        // physical length of the crossing region on each screen.
        let aIPP = vertical ? ra.height / max(a.bounds.height, 0.01) : ra.width / max(a.bounds.width, 0.01)
        let bIPP = vertical ? rb.height / max(b.bounds.height, 0.01) : rb.width / max(b.bounds.width, 0.01)

        // Each screen's point interval along the seam, from the reconstructed point
        // arrangement (falling back to its own bounds). These live in a common point
        // frame, so their intersection is the region a cursor crosses between them.
        func pointSpan(_ o: CGPoint?, _ d: DisplaySnapshot) -> (lo: CGFloat, hi: CGFloat) {
            let origin = o ?? d.bounds.origin
            return vertical ? (origin.y, origin.y + d.bounds.height)
                            : (origin.x, origin.x + d.bounds.width)
        }
        let pa = pointSpan(originA, a), pb = pointSpan(originB, b)

        // The crossing region: the shared point interval, identical on both screens.
        let lo = max(pa.lo, pb.lo), hi = min(pa.hi, pb.hi)
        let windowPoints = max(0, hi - lo)
        let center = (lo + hi) / 2
        // Its center as a point offset from each screen's own leading edge.
        let localA = center - pa.lo, localB = center - pb.lo
        let physA = physFromLocal(localA, physRect: ra, pointSize: a.bounds.size, vertical: vertical)
        let physB = physFromLocal(localB, physRect: rb, pointSize: b.bounds.size, vertical: vertical)

        return SeamBar(
            aID: a.id, bID: b.id, isVertical: vertical,
            physLine: line, physAlongA: physA, physAlongB: physB,
            localAlongA: localA, localAlongB: localB,
            windowPoints: windowPoints,
            // The same crossing region is physically longer on the coarser screen.
            physLenInchesA: windowPoints * aIPP, physLenInchesB: windowPoints * bIPP
        )
    }

    /// A physical along-coordinate from a point offset off the screen's leading edge.
    /// Lets the mini-map place a point-derived center on the physical plane.
    private static func physFromLocal(_ local: CGFloat, physRect: CGRect,
                                      pointSize: CGSize, vertical: Bool) -> CGFloat {
        if vertical {
            guard pointSize.height > 0 else { return physRect.midY }
            return physRect.minY + local / pointSize.height * physRect.height
        } else {
            guard pointSize.width > 0 else { return physRect.midX }
            return physRect.minX + local / pointSize.width * physRect.width
        }
    }
}
