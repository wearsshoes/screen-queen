import CoreGraphics

/// Shared alignment vocabulary. Where along a seam two displays line up is one of
/// these anchors; `SchematicLayout.physSnapsH/V` turn them into physical positions.
enum VAnchor: Equatable { case top, center, bottom }
enum HAnchor: Equatable { case left, center, right }

/// A keyboard/arrow move direction (`SchematicSnapping` plans nudges per direction).
enum MoveDirection {
    case up, down, left, right
    var isVertical: Bool { self == .up || self == .down }
}

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
        pinStraddlersOnPlane(eff, startID: start.id, out: &out, tol: tol)
        return out
    }

    /// Point→phys straddle pass (see `straddlePointPins` for the exact inverse): a display
    /// whose edge spans a junction between two same-side neighbors is re-anchored along that
    /// axis so the junction's *point* coordinate maps, at the display's own uniform scale,
    /// onto the neighbors' shared *physical* edge — its two seams then meet exactly where the
    /// pair meet. (A rigid single-scale tile can't also stay flush to one dock parent when
    /// densities differ; per design we privilege the junction.)
    ///
    /// When the straddler is the *start* display — it anchors the frame and never moves — the
    /// same constraint is satisfied in reverse: the junction *pair* slides (each partner set
    /// flush to the pinned junction, which also closes any placement drift between them) so
    /// their shared edge lands where the start's own map puts the point-junction. One pass:
    /// junction partners are assumed not to be straddlers themselves (chained straddles are
    /// out of scope).
    private static func pinStraddlersOnPlane(_ eff: [DisplaySnapshot], startID: CGDirectDisplayID,
                                             out: inout [CGDirectDisplayID: CGRect], tol: CGFloat) {
        typealias Pin = (dist: CGFloat, jPoint: CGFloat, jPhys: CGFloat,
                         a: CGDirectDisplayID, b: CGDirectDisplayID)
        for child in eff {
            guard let cr = out[child.id] else { continue }
            let c = child.bounds
            var pinX: Pin?
            var pinY: Pin?
            // Horizontal-seam straddle (junction along x): same-side pair below/above (y-down).
            for pairBelow in [true, false] {
                let side = eff.filter { n in
                    guard n.id != child.id, out[n.id] != nil else { return false }
                    let np = n.bounds
                    let touch = pairBelow ? abs(c.maxY - np.minY) <= tol : abs(c.minY - np.maxY) <= tol
                    return touch && min(c.maxX, np.maxX) - max(c.minX, np.minX) > 0
                }
                guard side.count >= 2 else { continue }
                for a in side { for b in side where b.id != a.id {
                    guard abs(a.bounds.maxX - b.bounds.minX) <= tol,          // a|b abut, a left
                          let ar = out[a.id], let br = out[b.id] else { continue }
                    let jPoint = (a.bounds.maxX + b.bounds.minX) / 2
                    guard jPoint > c.minX, jPoint < c.maxX else { continue }  // junction inside the child
                    let jPhys = (ar.maxX + br.minX) / 2
                    let dist = abs(jPoint - c.midX)
                    if pinX == nil || dist < pinX!.dist { pinX = (dist, jPoint, jPhys, a.id, b.id) }
                } }
            }
            // Vertical-seam straddle (junction along y): same-side pair right/left of the child.
            for pairRight in [true, false] {
                let side = eff.filter { n in
                    guard n.id != child.id, out[n.id] != nil else { return false }
                    let np = n.bounds
                    let touch = pairRight ? abs(c.maxX - np.minX) <= tol : abs(c.minX - np.maxX) <= tol
                    return touch && min(c.maxY, np.maxY) - max(c.minY, np.minY) > 0
                }
                guard side.count >= 2 else { continue }
                for a in side { for b in side where b.id != a.id {
                    guard abs(a.bounds.maxY - b.bounds.minY) <= tol,          // a stacked above b
                          let ar = out[a.id], let br = out[b.id] else { continue }
                    let jPoint = (a.bounds.maxY + b.bounds.minY) / 2
                    guard jPoint > c.minY, jPoint < c.maxY else { continue }
                    let jPhys = (ar.maxY + br.minY) / 2
                    let dist = abs(jPoint - c.midY)
                    if pinY == nil || dist < pinY!.dist { pinY = (dist, jPoint, jPhys, a.id, b.id) }
                } }
            }
            let isStart = child.id == startID
            if let p = pinX {
                let k = cr.width / max(c.width, 0.01)
                if isStart {
                    // Reverse: slide the pair so their shared edge sits where the start's own
                    // map puts the point-junction (a flush to its left, b flush to its right).
                    let desired = cr.minX + k * (p.jPoint - c.minX)
                    if let aw = out[p.a]?.width { out[p.a]!.origin.x = desired - aw }
                    out[p.b]?.origin.x = desired
                } else {
                    out[child.id]!.origin.x = p.jPhys - k * (p.jPoint - c.minX)
                }
            }
            if let p = pinY {
                let k = cr.height / max(c.height, 0.01)
                if isStart {
                    let desired = cr.minY + k * (p.jPoint - c.minY)
                    if let ah = out[p.a]?.height { out[p.a]!.origin.y = desired - ah }
                    out[p.b]?.origin.y = desired
                } else {
                    out[child.id]!.origin.y = p.jPhys - k * (p.jPoint - c.minY)
                }
            }
        }
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
            let parentID = queue.removeFirst()
            for child in displays where origins[child.id] == nil {
                guard rects[child.id] != nil else { continue }
                // Dock the child to the *best* already-placed neighbor, not just the queue
                // parent. A moved display's along-inverse can be ambiguous (nonmonotonic seam
                // map); if this child instead shares an *unambiguous* seam with another placed
                // display, dock to that one so the child lands at an exact abutment. This keeps
                // a seam between two displays that didn't move (e.g. two top monitors) intact
                // when a third (the main, below) slides underneath — the third's ambiguous
                // placement no longer leaks into where the untouched pair lands.
                guard let dock = dockOrigin(child: child, preferredParentID: parentID,
                                            origins: origins, rects: rects, byID: byID, tol: tol) else { continue }
                origins[child.id] = dock.origin
                queue.append(child.id)
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
        // Straddle pins need *both* junction partners placed, which the BFS can't guarantee at
        // dock time (order depends on the display list); re-apply now that everyone is placed.
        // Idempotent when the dock already pinned. When the *start* display is the straddler
        // it anchors the frame and never moves — satisfy its pin in reverse by sliding the
        // junction pair so their shared edge's point coordinate is where the start's own map
        // puts the physical junction (mirrors `pinStraddlersOnPlane`).
        for d in displays {
            guard origins[d.id] != nil, let cr = rects[d.id] else { continue }
            let pins = straddlePointPins(child: d, cr: cr, origins: origins, rects: rects, byID: byID, tol: tol)
            if d.id == start.id {
                if let p = pins.x {
                    let k = cr.width / max(d.bounds.width, 0.01)
                    let desired = d.bounds.minX + (p.jPhys - cr.minX) / k
                    if let aw = byID[p.a]?.bounds.width { origins[p.a]?.x = desired - aw }
                    origins[p.b]?.x = desired
                }
                if let p = pins.y {
                    let k = cr.height / max(d.bounds.height, 0.01)
                    let desired = d.bounds.minY + (p.jPhys - cr.minY) / k
                    if let ah = byID[p.a]?.bounds.height { origins[p.a]?.y = desired - ah }
                    origins[p.b]?.y = desired
                }
            } else {
                if let x = pins.x?.value { origins[d.id]!.x = x }
                if let y = pins.y?.value { origins[d.id]!.y = y }
            }
        }
        return origins
    }

    /// A drag-time point solve that holds the *unmoved* displays fixed. Only `dragged` is
    /// (re)placed each frame; every other display keeps its `locked` point origin. This makes
    /// the reconstruction reflect the physical truth of a drag — one display moves, the rest
    /// don't — so a seam between two untouched displays can't blink in and out as a side effect
    /// of re-interpreting the whole plane. The dragged display docks to whichever unmoved
    /// neighbor it now abuts (via `dockOrigin`), or, if it abuts none, is placed relative to the
    /// main at the main's density (the same disconnected fallback `toPoints` uses).
    ///
    /// "Up to translation": if `dragged` is the main, the locked origins were captured with the
    /// main at (0,0); we translate the whole result so the main stays at (0,0), preserving the
    /// invariant that geometry is defined only up to a global shift.
    static func lockedSolve(rects: [CGDirectDisplayID: CGRect], displays: [DisplaySnapshot],
                            locked: [CGDirectDisplayID: CGPoint], dragged: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint] {
        let byID = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard byID[dragged] != nil, rects[dragged] != nil else {
            return toPoints(rects: rects, displays: displays)   // dragged gone? fall back to full solve
        }
        // Freeze every unmoved display at its locked origin.
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for d in displays where d.id != dragged {
            if let o = locked[d.id] { origins[d.id] = o }
        }
        // If we somehow don't have a locked origin for an unmoved display, we can't honor the
        // lock — fall back to a normal solve rather than produce a half-frozen mess.
        guard origins.count == displays.count - 1 else {
            return toPoints(rects: rects, displays: displays)
        }
        let tol: CGFloat = 2
        // Place the dragged display against the frozen neighbors. `preferredParentID` is any
        // placed neighbor; `dockOrigin` picks the best exact-edge one on its own.
        let anyPlaced = origins.keys.first ?? dragged
        if let dock = dockOrigin(child: byID[dragged]!, preferredParentID: anyPlaced,
                                 origins: origins, rects: rects, byID: byID, tol: tol) {
            origins[dragged] = dock.origin
        } else if let mainID = displays.first(where: { $0.isMain })?.id,
                  let mr = rects[mainID], let mo = origins[mainID] ?? (mainID == dragged ? .zero : nil) {
            // Disconnected: place relative to the main at the main's density.
            let m = byID[mainID]!
            let kx = m.bounds.width / max(mr.width, 0.01), ky = m.bounds.height / max(mr.height, 0.01)
            let dr = rects[dragged]!
            origins[dragged] = CGPoint(x: mo.x + (dr.minX - mr.minX) * kx, y: mo.y + (dr.minY - mr.minY) * ky)
        } else {
            return toPoints(rects: rects, displays: displays)
        }
        // Normalize so the main sits at (0,0) (defined only up to translation).
        if let mainID = displays.first(where: { $0.isMain })?.id, let mo = origins[mainID], mo != .zero {
            for id in origins.keys { origins[id]!.x -= mo.x; origins[id]!.y -= mo.y }
        }
        return origins
    }

    /// Where `child` docks in point space: its perpendicular flush against a placed neighbor
    /// plus its resolved along-coordinate.
    ///
    /// The key invariant: if the child shares an **exact** physical edge with an already-placed
    /// neighbor, it must land flush against that neighbor in point space (a shared physical
    /// seam stays a shared point seam). A neighbor with a truly-exact edge (near-zero gap) wins
    /// outright over the queue parent — so when a third display (e.g. the moved main) slides
    /// under two that abut each other, the pair's mutual seam is preserved regardless of the
    /// mover's own (possibly ambiguous, position-dependent) seam map. Among exact-edge
    /// neighbors we take the lowest id, so the choice is stable frame to frame. When no neighbor
    /// abuts exactly, fall back to the queue parent (then any bordering neighbor).
    ///
    /// Also reports `ambiguous`: whether the resolved position actually *relied* on a folded
    /// (>1-preimage) inverse. A seam pins its perpendicular axis hard and only *resolves* the
    /// along axis through the inverse map, so only that axis can be ambiguous — and an
    /// L-junction's perpendicular flush or a straddle pin settles it. Genuinely ambiguous means
    /// "she had to guess," not "some neighboring map has a fold somewhere."
    private static func dockOrigin(child: DisplaySnapshot, preferredParentID: CGDirectDisplayID,
                                   origins: [CGDirectDisplayID: CGPoint],
                                   rects: [CGDirectDisplayID: CGRect],
                                   byID: [CGDirectDisplayID: DisplaySnapshot],
                                   tol: CGFloat) -> (origin: CGPoint, ambiguous: Bool)? {
        let cr = rects[child.id]!, cs = child.bounds.size, cPhys = physSize(child)

        // A candidate docking against placed neighbor `n`: the child's origin, the physical
        // edge gap (how exactly they abut — smaller is a truer shared seam), how ambiguous that
        // neighbor's along-inverse is (its preimage count; the *moved* display is the one with a
        // nonmonotonic, >1-preimage map, so a low count marks the stable neighbor), and the seam
        // orientation. A *vertical* seam pins the child's x (a hard constraint) and resolves its
        // y; a *horizontal* seam pins y and resolves x. That per-axis split is what lets an
        // L-junction satisfy two perpendicular neighbors at once.
        func candidate(_ nid: CGDirectDisplayID) -> (origin: CGPoint, gap: CGFloat, preimages: Int, vertical: Bool)? {
            guard let n = byID[nid], let nr = rects[nid], let no = origins[nid] else { return nil }
            let np = CGRect(origin: no, size: n.bounds.size)
            let yOv = min(nr.maxY, cr.maxY) - max(nr.minY, cr.minY)
            let xOv = min(nr.maxX, cr.maxX) - max(nr.minX, cr.minX)
            func alongV() -> (CGFloat, Int) {   // child's point y from its physical minY
                let a = seamPointResolved(cr.minY, seamAnchors(child: child, cPhys, parentPoint: np, parentPhys: nr, vertical: true))
                return (a.point, a.preimages)
            }
            func alongH() -> (CGFloat, Int) {   // child's point x from its physical minX
                let a = seamPointResolved(cr.minX, seamAnchors(child: child, cPhys, parentPoint: np, parentPhys: nr, vertical: false))
                return (a.point, a.preimages)
            }
            if abs(cr.minX - nr.maxX) <= tol, yOv > -tol {           // child right of n (vertical seam)
                let (y, pre) = alongV(); return (CGPoint(x: np.maxX, y: y), abs(cr.minX - nr.maxX), pre, true)
            } else if abs(cr.maxX - nr.minX) <= tol, yOv > -tol {    // child left of n
                let (y, pre) = alongV(); return (CGPoint(x: np.minX - cs.width, y: y), abs(cr.maxX - nr.minX), pre, true)
            } else if abs(cr.minY - nr.maxY) <= tol, xOv > -tol {    // child below n (horizontal seam, y-down)
                let (x, pre) = alongH(); return (CGPoint(x: x, y: np.maxY), abs(cr.minY - nr.maxY), pre, false)
            } else if abs(cr.maxY - nr.minY) <= tol, xOv > -tol {    // child above n
                let (x, pre) = alongH(); return (CGPoint(x: x, y: np.minY - cs.height), abs(cr.maxY - nr.minY), pre, false)
            }
            return nil
        }

        // Exact-edge neighbors (gap ≈ 0) are hard constraints. Rank by unambiguous inverse
        // (fewest preimages — the stationary neighbor, not the moved one), then tightest gap,
        // then lowest id (frame-stable).
        let exactTol: CGFloat = 0.5
        typealias Cand = (origin: CGPoint, gap: CGFloat, preimages: Int, vertical: Bool)
        var exact: [(id: CGDirectDisplayID, c: Cand)] = []
        for nid in origins.keys.sorted() {
            guard let c = candidate(nid), c.gap <= exactTol else { continue }
            exact.append((id: nid, c: c))
        }
        exact.sort { a, b in
            if a.c.preimages != b.c.preimages { return a.c.preimages < b.c.preimages }
            if a.c.gap != b.c.gap { return a.c.gap < b.c.gap }
            return a.id < b.id
        }
        var resolved: CGPoint?
        // The axis whose value came from a folded (>1-preimage) inverse; cleared when a
        // harder constraint (L-junction flush, straddle pin) settles that axis.
        enum Axis { case x, y }
        var foldAxis: Axis?
        func markFold(_ c: Cand) { if c.preimages > 1 { foldAxis = c.vertical ? .y : .x } }
        if let best = exact.first {
            // L-junction: if another exact neighbor sits on the *perpendicular* axis, it pins
            // the coordinate `best` only resolved (didn't constrain). Take that pinned axis from
            // the best perpendicular neighbor so the child settles into the corner against both.
            var origin = best.c.origin
            markFold(best.c)
            if let perp = exact.first(where: { $0.c.vertical != best.c.vertical }) {
                if best.c.vertical { origin.y = perp.c.origin.y; if foldAxis == .y { foldAxis = nil } }
                else               { origin.x = perp.c.origin.x; if foldAxis == .x { foldAxis = nil } }
            }
            resolved = origin
        } else if let base = candidate(preferredParentID) {
            // No exact-edge neighbor: dock to the queue parent, else any bordering neighbor.
            resolved = base.origin
            markFold(base)
        } else {
            for nid in origins.keys.sorted() where nid != preferredParentID {
                if let c = candidate(nid) { resolved = c.origin; markFold(c); break }
            }
        }
        guard var origin = resolved else { return nil }
        // Straddle pin: a junction the child spans overrides the along-axis, so the child's
        // two seams meet exactly where the pair below/beside it meet (see straddlePointPins).
        let pins = straddlePointPins(child: child, cr: cr, origins: origins, rects: rects, byID: byID, tol: tol)
        if let x = pins.x?.value { origin.x = x; if foldAxis == .x { foldAxis = nil } }
        if let y = pins.y?.value { origin.y = y; if foldAxis == .y { foldAxis = nil } }
        return (origin, foldAxis != nil)
    }

    /// Phys→point straddle pins for `child` (physical rect `cr`): when the child spans a
    /// *junction* — two placed neighbors on the same side of it that abut each other within
    /// its span — the junction's shared physical edge must map, through the child's own
    /// uniform scale, back to the junction's *point* coordinate. That anchors the child's
    /// along-axis so its two seams meet exactly where the pair meet (the rendered junction
    /// line), rather than inheriting one parent's far-edge anchor. Returns the pinned
    /// point-origin coordinate per axis (nil = no straddle on that axis), along with the
    /// junction it was pinned to (`jPoint`/`jPhys` and the pair `a`|`b`) so a caller pinning
    /// the *start* display can satisfy the constraint in reverse by moving the pair. Exactly
    /// mirrors `pinStraddlersOnPlane` (the point→phys direction), so commit and interpret stay
    /// faithful inverses; at the moment a junction crosses the child's edge the pin agrees
    /// with the single-parent anchor map (the shared edges-aligned anchor), so drag handoffs
    /// are continuous.
    // TODO: expose the fold/straddle resolution as direct manipulation in the arranger — a
    // draggable bar along the seam with a perpendicular *pin handle* (à la image-editing
    // guides) that lets the user say which subsection of a neighbor an edge actually maps to.
    // Genuinely folded cases (equal physical size, unequal densities, exactly parallel) have
    // no single right answer; today a junction/L-flush picks one, but the handle would make
    // the choice visible and adjustable, and double as a snap target. Not an immediate feature.
    typealias StraddlePin = (value: CGFloat, jPoint: CGFloat, jPhys: CGFloat,
                             a: CGDirectDisplayID, b: CGDirectDisplayID)
    private static func straddlePointPins(child: DisplaySnapshot, cr: CGRect,
                                          origins: [CGDirectDisplayID: CGPoint],
                                          rects: [CGDirectDisplayID: CGRect],
                                          byID: [CGDirectDisplayID: DisplaySnapshot],
                                          tol: CGFloat) -> (x: StraddlePin?, y: StraddlePin?) {
        let c = child.bounds
        var pinX: (dist: CGFloat, pin: StraddlePin)?
        var pinY: (dist: CGFloat, pin: StraddlePin)?
        let placed = origins.keys.filter { $0 != child.id }
        // Horizontal-seam straddle (junction along x): a same-side pair — both below or both
        // above the child (y-down) — abutting left|right inside the child's span pins its x.
        for pairBelow in [true, false] {
            let side = placed.filter { nid in
                guard let nr = rects[nid] else { return false }
                let touch = pairBelow ? abs(cr.maxY - nr.minY) <= tol : abs(cr.minY - nr.maxY) <= tol
                return touch && min(cr.maxX, nr.maxX) - max(cr.minX, nr.minX) > 0
            }
            guard side.count >= 2 else { continue }
            for a in side { for b in side where b != a {
                guard let ar = rects[a], let br = rects[b], let ao = origins[a], let bo = origins[b],
                      let an = byID[a] else { continue }
                guard abs(ar.maxX - br.minX) <= 0.5 else { continue }     // a|b abut, a on the left
                let jPhys = (ar.maxX + br.minX) / 2
                guard jPhys > cr.minX, jPhys < cr.maxX else { continue }  // junction inside the child
                let jPoint = ao.x + an.bounds.width
                guard abs(bo.x - jPoint) <= tol else { continue }         // and abut in point space
                let k = cr.width / max(c.width, 0.01)                     // child inches per point
                let dist = abs(jPhys - cr.midX)                           // several junctions → nearest to center
                if pinX == nil || dist < pinX!.dist {
                    pinX = (dist, (jPoint - (jPhys - cr.minX) / k, jPoint, jPhys, a, b))
                }
            } }
        }
        // Vertical-seam straddle (junction along y): a same-side pair — both right or both
        // left of the child — stacked top|bottom inside the child's span pins its y.
        for pairRight in [true, false] {
            let side = placed.filter { nid in
                guard let nr = rects[nid] else { return false }
                let touch = pairRight ? abs(cr.maxX - nr.minX) <= tol : abs(cr.minX - nr.maxX) <= tol
                return touch && min(cr.maxY, nr.maxY) - max(cr.minY, nr.minY) > 0
            }
            guard side.count >= 2 else { continue }
            for a in side { for b in side where b != a {
                guard let ar = rects[a], let br = rects[b], let ao = origins[a], let bo = origins[b],
                      let an = byID[a] else { continue }
                guard abs(ar.maxY - br.minY) <= 0.5 else { continue }     // a stacked above b (y-down)
                let jPhys = (ar.maxY + br.minY) / 2
                guard jPhys > cr.minY, jPhys < cr.maxY else { continue }
                let jPoint = ao.y + an.bounds.height
                guard abs(bo.y - jPoint) <= tol else { continue }
                let k = cr.height / max(c.height, 0.01)
                let dist = abs(jPhys - cr.midY)
                if pinY == nil || dist < pinY!.dist {
                    pinY = (dist, (jPoint - (jPhys - cr.minY) / k, jPoint, jPhys, a, b))
                }
            } }
        }
        return (pinX?.pin, pinY?.pin)
    }

    // MARK: - Solve trace (powers the arranger's "what she sees" panel)

    /// A read-only trace of the point-space reconstruction: each display's reconstructed
    /// point rect, whether it docked through an *ambiguous* (>1-preimage) inverse, and the
    /// point-space seams the solve produced. Mirrors `toPoints` but records diagnostics;
    /// kept separate so the production path stays unchanged.
    struct SolveTrace {
        var pointRects: [(id: CGDirectDisplayID, rect: CGRect, ambiguous: Bool, dockedTo: CGDirectDisplayID?)] = []
        var seams: [(a: CGDirectDisplayID, b: CGDirectDisplayID, vertical: Bool)] = []
    }

    static func solveTrace(rects: [CGDirectDisplayID: CGRect], displays: [DisplaySnapshot]) -> SolveTrace {
        var out = SolveTrace()
        guard !displays.isEmpty else { return out }
        let byID = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let start = displays.first(where: { $0.isMain }) ?? displays[0]
        guard rects[start.id] != nil else { return out }
        var origins: [CGDirectDisplayID: CGPoint] = [start.id: .zero]
        var meta: [CGDirectDisplayID: (ambiguous: Bool, dockedTo: CGDirectDisplayID?)] = [start.id: (false, nil)]
        var queue = [start.id]
        let tol: CGFloat = 2
        while !queue.isEmpty {
            let parentID = queue.removeFirst()
            for child in displays where origins[child.id] == nil {
                guard rects[child.id] != nil else { continue }
                guard let dock = dockOrigin(child: child, preferredParentID: parentID,
                                            origins: origins, rects: rects, byID: byID, tol: tol) else { continue }
                origins[child.id] = dock.origin
                queue.append(child.id)
                // The dock itself reports whether the *chosen* resolution relied on a folded
                // inverse — a fold on some unused neighboring seam (e.g. two same-size panels'
                // mutual map, when both are actually pinned by a third display) doesn't count.
                meta[child.id] = (dock.ambiguous, nil)
            }
        }
        for d in displays {
            guard let o = origins[d.id] else { continue }
            let m = meta[d.id] ?? (false, nil)
            out.pointRects.append((d.id, CGRect(origin: o, size: d.bounds.size), m.ambiguous, m.dockedTo))
        }
        // Point-space seams (same test seamBars uses).
        for i in 0..<out.pointRects.count {
            for j in (i + 1)..<out.pointRects.count {
                if let s = seam(out.pointRects[i].rect, out.pointRects[j].rect) {
                    out.seams.append((out.pointRects[i].id, out.pointRects[j].id, s.vertical))
                }
            }
        }
        return out
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
        // orientation). Collect the point value each *containing* segment inverts to; the
        // first (forward's own point order) is the answer. The ambiguity is the number of
        // *distinct* preimage points — not the raw segment count: when displays are the same
        // size and edge-aligned the anchors collapse into duplicates, so several degenerate
        // segments all invert to the same point. That's genuinely unambiguous (one preimage),
        // and must not read as ambiguous (it would mis-rank a clean same-size neighbor).
        var first: CGFloat?
        var distinct: [CGFloat] = []
        for i in 0..<(p.count - 1) {
            let lo = min(p[i].1, p[i + 1].1), hi = max(p[i].1, p[i + 1].1)
            guard physAlong >= lo, physAlong <= hi else { continue }
            let pt = inv(p[i], p[i + 1])
            if first == nil { first = pt }
            if !distinct.contains(where: { abs($0 - pt) < 1 }) { distinct.append(pt) }
        }
        if let first { return (first, distinct.count) }
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
                         rects: [CGDirectDisplayID: CGRect],
                         origins precomputed: [CGDirectDisplayID: CGPoint]? = nil) -> [SeamBar] {
        // A bar answers "if my cursor crosses here, what display do I land on?", so
        // adjacency is decided in *point* space (where the cursor lives), not on the
        // physical plane — two screens can be point-adjacent while their physical rects,
        // scaled by differing density, only corner-touch (or vice versa). Reconstruct
        // the point arrangement and find seams there. During a drag the caller passes the
        // locked solve (unmoved displays frozen) so untouched seams stay put.
        let origins = precomputed ?? toPoints(rects: rects, displays: displays)
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
