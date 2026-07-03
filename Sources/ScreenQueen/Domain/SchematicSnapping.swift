import CoreGraphics

/// Pure plane-space snapping and keyboard-alignment geometry: given the current plane
/// (physical-inch rects, y-down, domain-native) and the active anchor markers, compute
/// where a dragged or nudged tile should land — and which markers result.
///
/// Transform-free and stage-free: it takes plane rects in and returns plane origins out,
/// with the active-marker side effect turned into a return value. The stage is the only
/// place that reads/writes state; here it's all inputs and outputs, so the logic is
/// testable in isolation.
enum SchematicSnapping {

    /// The two active-anchor markers, matching `ArrangerState`'s storage shape so call
    /// sites assign the result directly without conversion.
    typealias VMarker = (selfA: VAnchor, otherA: VAnchor, otherID: CGDirectDisplayID)
    typealias HMarker = (selfA: HAnchor, otherA: HAnchor, otherID: CGDirectDisplayID)

    /// Result of a snap: where the tile lands, plus the markers it produced (nil ⇒ clear).
    struct Snap {
        let origin: CGPoint
        let activeV: VMarker?
        let activeH: HMarker?
    }

    // MARK: - Drag docking + magnet snapping

    /// Dock `dragged` (size `dP`) flush to the nearest neighbor in `others` without
    /// overlapping, magnet the along-axis to a physical anchor, then prefer an L-corner
    /// seat against a second neighbor. `scale` (view px per inch) sets the magnet radius.
    /// `snap == false` ⇒ free placement (no docking).
    static func dockAndSnap(dragged dP: CGSize, id: CGDirectDisplayID, free: CGPoint,
                            scale: CGFloat, snap: Bool,
                            plane: [CGDirectDisplayID: CGRect]) -> Snap {
        let others = plane.filter { $0.key != id }
        guard snap, !others.isEmpty else { return Snap(origin: free, activeV: nil, activeH: nil) }

        // 1) Dock flush to the nearest neighbor without overlapping.
        var best = free, bestDist = CGFloat.greatestFiniteMagnitude
        var neighbor: (id: CGDirectDisplayID, rect: CGRect)?, verticalSeam = true
        for (oid, oR) in others {
            let yA = clamp(free.y, oR.minY - dP.height + 0.05, oR.maxY - 0.05)
            let xA = clamp(free.x, oR.minX - dP.width + 0.05, oR.maxX - 0.05)
            let candidates: [(CGPoint, Bool)] = [
                (CGPoint(x: oR.maxX, y: yA), true), (CGPoint(x: oR.minX - dP.width, y: yA), true),
                (CGPoint(x: xA, y: oR.maxY), false), (CGPoint(x: xA, y: oR.minY - dP.height), false),
            ]
            for (cand, vert) in candidates {
                let rect = CGRect(origin: cand, size: dP).insetBy(dx: 0.1, dy: 0.1)
                if others.contains(where: { $0.value.intersects(rect) }) { continue }
                let d = hypot(cand.x - free.x, cand.y - free.y)
                if d < bestDist { bestDist = d; best = cand; neighbor = (oid, oR); verticalSeam = vert }
            }
        }
        guard let o = neighbor else { return Snap(origin: free, activeV: nil, activeH: nil) }

        var activeV: VMarker?
        var activeH: HMarker?

        // 2) Magnet the slide to a physical anchor of the docked-to neighbor (within a
        //    few view px). The primary dock fixes the perpendicular axis; here we snap
        //    the *along* axis.
        let threshold = 5 / max(scale, 0.0001) // inches
        if verticalSeam {
            var bestD = threshold
            for s in SchematicLayout.physSnapsV(childHeight: dP.height, parent: o.rect) where abs(s.along - best.y) < bestD {
                bestD = abs(s.along - best.y); best.y = s.along; activeV = (s.selfAnchor, s.otherAnchor, o.id)
            }
        } else {
            var bestD = threshold
            for s in SchematicLayout.physSnapsH(childWidth: dP.width, parent: o.rect) where abs(s.along - best.x) < bestD {
                bestD = abs(s.along - best.x); best.x = s.along; activeH = (s.selfAnchor, s.otherAnchor, o.id)
            }
        }

        // 3) Corner detent: with the tile docked to the primary neighbor, look for a
        //    *second* neighbor it can also seat flush against along the free axis, and
        //    prefer that (so dragging into an L-corner snaps into the corner). Only a
        //    second neighbor that would actually overlap the tile's docked span counts.
        let corner = cornerSnap(best, size: dP, along: verticalSeam, primary: o.id,
                                threshold: threshold, others: others)
        best = corner.origin
        // The corner seat sets the perpendicular marker; keep the along-axis magnet marker.
        if let cv = corner.activeV { activeV = cv }
        if let ch = corner.activeH { activeH = ch }
        return Snap(origin: best, activeV: activeV, activeH: activeH)
    }

    /// If, once docked to the primary neighbor, the tile can also sit flush against a
    /// second neighbor along the free axis (within `threshold`), snap it there so it
    /// seats into the corner — setting the perpendicular active marker too. `along`
    /// vertical ⇒ the free axis is y (snap top/bottom to a second neighbor's edge).
    private static func cornerSnap(_ pos: CGPoint, size dP: CGSize, along verticalSeam: Bool,
                                   primary: CGDirectDisplayID, threshold: CGFloat,
                                   others: [CGDirectDisplayID: CGRect]) -> Snap {
        var best = pos, bestD = threshold, snapped = false
        var snappedID: CGDirectDisplayID?, snapEdgeIsMin = false
        // A candidate along-position is only valid if seating there doesn't overlap any
        // other display (it can slide into a third tile).
        func clear(_ origin: CGPoint) -> Bool {
            let rect = CGRect(origin: origin, size: dP).insetBy(dx: 0.1, dy: 0.1)
            return !others.contains { $0.value.intersects(rect) }
        }
        for (oid, oR) in others where oid != primary {
            if verticalSeam {
                // Free axis is y; a second neighbor whose x abuts the tile can seat its
                // top or bottom flush. Require x-overlap so it's genuinely a corner.
                guard min(pos.x + dP.width, oR.maxX) - max(pos.x, oR.minX) > 0.05 else { continue }
                for (edge, isMin) in [(oR.minY - dP.height, false), (oR.maxY, true)] {
                    let d = abs(edge - pos.y)
                    if d < bestD, clear(CGPoint(x: pos.x, y: edge)) {
                        bestD = d; best.y = edge; snapped = true; snappedID = oid; snapEdgeIsMin = isMin
                    }
                }
            } else {
                guard min(pos.y + dP.height, oR.maxY) - max(pos.y, oR.minY) > 0.05 else { continue }
                for (edge, isMin) in [(oR.minX - dP.width, false), (oR.maxX, true)] {
                    let d = abs(edge - pos.x)
                    if d < bestD, clear(CGPoint(x: edge, y: pos.y)) {
                        bestD = d; best.x = edge; snapped = true; snappedID = oid; snapEdgeIsMin = isMin
                    }
                }
            }
        }
        // Reflect the second seam in the perpendicular marker (self meets the second
        // neighbor edge-to-edge: our leading edge on its trailing edge, or vice versa).
        var activeV: VMarker?
        var activeH: HMarker?
        if snapped, let sid = snappedID {
            // snapEdgeIsMin ⇒ tile seated on the neighbor's max edge (tile below/right):
            // tile's leading edge meets the neighbor's trailing edge, and vice versa.
            if verticalSeam {
                activeV = snapEdgeIsMin ? (.top, .bottom, sid) : (.bottom, .top, sid)
            } else {
                activeH = snapEdgeIsMin ? (.left, .right, sid) : (.right, .left, sid)
            }
        }
        return Snap(origin: best, activeV: activeV, activeH: activeH)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        // A neighbor smaller than the dragged tile can invert the bounds; center then.
        lo <= hi ? min(max(v, lo), hi) : (lo + hi) / 2
    }

    // MARK: - Keyboard alignment

    struct Join { let otherID: CGDirectDisplayID; let vertical: Bool; let aPositive: Bool }

    /// The display `id`'s current docking against a neighbor on the plane.
    static func currentJoin(_ id: CGDirectDisplayID, plane: [CGDirectDisplayID: CGRect]) -> Join? {
        guard let A = plane[id] else { return nil }
        let tol: CGFloat = 0.1
        for (oid, O) in plane where oid != id {
            let yOv = min(A.maxY, O.maxY) - max(A.minY, O.minY)
            let xOv = min(A.maxX, O.maxX) - max(A.minX, O.minX)
            if abs(A.minX - O.maxX) <= tol, yOv > tol { return Join(otherID: oid, vertical: true, aPositive: true) }
            if abs(A.maxX - O.minX) <= tol, yOv > tol { return Join(otherID: oid, vertical: true, aPositive: false) }
            if abs(A.minY - O.maxY) <= tol, xOv > tol { return Join(otherID: oid, vertical: false, aPositive: true) }
            if abs(A.maxY - O.minY) <= tol, xOv > tol { return Join(otherID: oid, vertical: false, aPositive: false) }
        }
        return nil
    }

    /// Every ⌘⇧-arrow direction that would move the tile, mapped to the plane origin it
    /// would land on (no-op directions omitted). The ghost preview and the apply step both
    /// read this, so what's previewed is what applies.
    static func plannedMoves(_ id: CGDirectDisplayID,
                             plane: [CGDirectDisplayID: CGRect],
                             activeV: VMarker?, activeH: HMarker?) -> [MoveDirection: CGPoint] {
        var moves: [MoveDirection: CGPoint] = [:]
        for d in [MoveDirection.up, .down, .left, .right] {
            if let o = plannedOrigin(id, d, plane: plane, activeV: activeV, activeH: activeH) {
                moves[d] = o
            }
        }
        return moves
    }

    /// Where the selected tile would go for `dir`, without applying it — pure, so the ⌘⇧
    /// ghost preview can show each valid arrow's destination. nil ⇒ no-op. The along-seam
    /// arrow cycles the anchors (wrapping around the corner at an end); the across-seam
    /// arrow flips the tile to the neighbor's edge, walking it around like a clock.
    static func plannedOrigin(_ id: CGDirectDisplayID, _ dir: MoveDirection,
                              plane: [CGDirectDisplayID: CGRect],
                              activeV: VMarker?, activeH: HMarker?) -> CGPoint? {
        guard let join = currentJoin(id, plane: plane) else { return nil }
        if join.vertical {   // seam is vertical → along = up/down, across = left/right
            return dir.isVertical ? cycleOrigin(id, other: join.otherID, vertical: true, increasing: dir == .down, plane: plane, activeV: activeV, activeH: activeH)
                                  : flipOrigin(id, around: join.otherID, dir: dir, plane: plane)
        } else {             // seam is horizontal → along = left/right, across = up/down
            return !dir.isVertical ? cycleOrigin(id, other: join.otherID, vertical: false, increasing: dir == .right, plane: plane, activeV: activeV, activeH: activeH)
                                   : flipOrigin(id, around: join.otherID, dir: dir, plane: plane)
        }
    }

    /// Origin one anchor along the seam; at an extreme, wraps around the corner.
    static func cycleOrigin(_ id: CGDirectDisplayID, other oid: CGDirectDisplayID, vertical: Bool,
                            increasing: Bool, plane: [CGDirectDisplayID: CGRect],
                            activeV: VMarker?, activeH: HMarker?) -> CGPoint? {
        guard let r = plane[id], let oR = plane[oid] else { return nil }
        let step = increasing ? 1 : -1
        if vertical {
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: oR)
            let cur = activeV?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeV!.selfA && $0.otherAnchor == activeV!.otherA } ?? nearestIndex(snaps.map(\.along), r.minY))
                : nearestIndex(snaps.map(\.along), r.minY)
            let next = cur + step
            if next < 0 || next >= snaps.count { return wrapOrigin(id, around: oid, fromVerticalSeam: true, increasing: increasing, plane: plane) }
            return CGPoint(x: r.minX, y: snaps[next].along)
        } else {
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: oR)
            let cur = activeH?.otherID == oid
                ? (snaps.firstIndex { $0.selfAnchor == activeH!.selfA && $0.otherAnchor == activeH!.otherA } ?? nearestIndex(snaps.map(\.along), r.minX))
                : nearestIndex(snaps.map(\.along), r.minX)
            let next = cur + step
            if next < 0 || next >= snaps.count { return wrapOrigin(id, around: oid, fromVerticalSeam: false, increasing: increasing, plane: plane) }
            return CGPoint(x: snaps[next].along, y: r.minY)
        }
    }

    static func nearestIndex(_ values: [CGFloat], _ current: CGFloat) -> Int {
        var bestI = 0, bestD = CGFloat.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where abs(v - current) < bestD { bestD = abs(v - current); bestI = i }
        return bestI
    }

    /// Origin on the neighbor's edge in the pressed direction, same along-anchor — nil if
    /// already on that side (no toggle-back). Up→above, Down→below, etc.
    static func flipOrigin(_ id: CGDirectDisplayID, around oid: CGDirectDisplayID,
                           dir: MoveDirection, plane: [CGDirectDisplayID: CGRect]) -> CGPoint? {
        guard let r = plane[id], let O = plane[oid] else { return nil }
        switch dir {
        case .left  where r.minX > O.minX: return CGPoint(x: O.minX - r.width, y: r.minY)
        case .right where r.maxX < O.maxX: return CGPoint(x: O.maxX, y: r.minY)
        case .up    where r.minY > O.minY: return CGPoint(x: r.minX, y: O.minY - r.height)
        case .down  where r.maxY < O.maxY: return CGPoint(x: r.minX, y: O.maxY)
        default: return nil   // already on that side
        }
    }

    /// Origin after wrapping onto the perpendicular edge (turning the corner), snapped to
    /// the corner anchor it wrapped past.
    static func wrapOrigin(_ id: CGDirectDisplayID, around oid: CGDirectDisplayID,
                           fromVerticalSeam: Bool, increasing: Bool,
                           plane: [CGDirectDisplayID: CGRect]) -> CGPoint? {
        guard let r = plane[id], let O = plane[oid] else { return nil }
        if fromVerticalSeam {
            let onRight = abs(r.minX - O.maxX) < 0.1
            let y = increasing ? O.maxY : O.minY - r.height        // below / above O
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: O)
            return CGPoint(x: (onRight ? snaps.last! : snaps.first!).along, y: y)
        } else {
            let below = abs(r.minY - O.maxY) < 0.1
            let x = increasing ? O.maxX : O.minX - r.width         // right / left of O
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: O)
            return CGPoint(x: x, y: (below ? snaps.last! : snaps.first!).along)
        }
    }

    /// The active-anchor marker for a tile's current join (nil ⇒ no join). Returns which
    /// axis is active via the tuple that's non-nil.
    static func markerForJoin(_ id: CGDirectDisplayID,
                              plane: [CGDirectDisplayID: CGRect]) -> (v: VMarker?, h: HMarker?) {
        guard let r = plane[id], let join = currentJoin(id, plane: plane), let oR = plane[join.otherID] else {
            return (nil, nil)
        }
        if join.vertical {
            let snaps = SchematicLayout.physSnapsV(childHeight: r.height, parent: oR)
            let i = nearestIndex(snaps.map(\.along), r.minY)
            return ((snaps[i].selfAnchor, snaps[i].otherAnchor, join.otherID), nil)
        } else {
            let snaps = SchematicLayout.physSnapsH(childWidth: r.width, parent: oR)
            let i = nearestIndex(snaps.map(\.along), r.minX)
            return (nil, (snaps[i].selfAnchor, snaps[i].otherAnchor, join.otherID))
        }
    }
}
