import CoreGraphics

/// The pure geometry/set rules behind hotplug handling (`AppDelegate+Hotplug`):
/// whether a point arrangement is valid, whether two rects touch edge-to-edge,
/// whether a newcomer is an identical twin of a present monitor, and where to dock
/// a newcomer. Framework-free and tested — this is the code most likely to silently
/// scramble someone's monitors.
enum HotplugMath {

    /// Which hotplug branch a refresh takes, from the identity sets alone. This is the
    /// decision `handleProfiles` acts on; keeping it pure means the branch logic — the
    /// part that picks *what happens to your monitors* — is testable without a display.
    enum Transition: Equatable {
        case ignore                                        // empty set (all screens gone)
        case settled                                       // same set → remember this layout
        case departure                                     // display(s) left → repin survivors
        case twinJoined(newcomers: Set<CGDirectDisplayID>) // identical twin → dock, don't reshuffle
        case setChanged(newcomers: Set<CGDirectDisplayID>) // profile lookup path
    }

    static func transition(set: Set<String>, baseSet: [String], ids: Set<CGDirectDisplayID>,
                           lastSet: Set<String>, lastBaseSet: [String],
                           lastIDs: Set<CGDirectDisplayID>) -> Transition {
        guard !set.isEmpty else { return .ignore }
        guard set != lastSet else { return .settled }
        let newcomers = ids.subtracting(lastIDs)
        let removed = lastIDs.subtracting(ids)
        if !removed.isEmpty, newcomers.isEmpty { return .departure }
        if joinedIdenticalTwin(now: baseSet, before: lastBaseSet) { return .twinJoined(newcomers: newcomers) }
        return .setChanged(newcomers: newcomers)
    }

    /// What to do about survivors after a departure: re-apply their prior origins, or
    /// hand the layout to the user. Solve when any survivor's prior spot is unknown, or
    /// when the priors no longer form a valid arrangement (e.g. the middle of three left).
    enum RepinDecision: Equatable {
        case apply(origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID?)
        case solveInArranger
    }

    static func repinDecision(survivors: [(id: CGDirectDisplayID, size: CGSize, isMain: Bool)],
                              priorOrigins: [CGDirectDisplayID: CGPoint]) -> RepinDecision {
        var rects: [CGRect] = []
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        for d in survivors {
            guard let o = priorOrigins[d.id] else { return .solveInArranger }
            origins[d.id] = o
            rects.append(CGRect(origin: o, size: d.size))
            if d.isMain { mainID = d.id }
        }
        guard arrangementIsValid(rects) else { return .solveInArranger }
        return .apply(origins: origins, mainID: mainID)
    }

    /// Whether `rects` form a connected, non-overlapping arrangement (each touches
    /// another edge-to-edge, none overlap).
    static func arrangementIsValid(_ rects: [CGRect]) -> Bool {
        guard rects.count > 1 else { return true }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count where rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)) {
                return false   // overlap
            }
        }
        // Connectivity: BFS over edge-adjacency must reach every rect.
        var seen = Set([0]); var queue = [0]
        while let k = queue.popLast() {
            for n in 0..<rects.count where !seen.contains(n) && edgeAdjacent(rects[k], rects[n]) {
                seen.insert(n); queue.append(n)
            }
        }
        return seen.count == rects.count
    }

    static func edgeAdjacent(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 2
        let xTouch = abs(a.maxX - b.minX) <= tol || abs(b.maxX - a.minX) <= tol
        let yTouch = abs(a.maxY - b.minY) <= tol || abs(b.maxY - a.minY) <= tol
        let yOv = min(a.maxY, b.maxY) - max(a.minY, b.minY) > tol
        let xOv = min(a.maxX, b.maxX) - max(a.minX, b.minX) > tol
        return (xTouch && yOv) || (yTouch && xOv)
    }

    /// True when the base v/m/s multiset grew by exactly one that was already present —
    /// i.e. a second identical monitor was plugged in.
    static func joinedIdenticalTwin(now baseSet: [String], before lastBaseSet: [String]) -> Bool {
        guard baseSet.count == lastBaseSet.count + 1 else { return false }
        let before = Dictionary(lastBaseSet.map { ($0, 1) }, uniquingKeysWith: +)
        let now = Dictionary(baseSet.map { ($0, 1) }, uniquingKeysWith: +)
        // Exactly one base id increased its count, and it was already present before.
        let grown = now.filter { $0.value > (before[$0.key] ?? 0) }
        return grown.count == 1 && (before[grown.keys.first!] ?? 0) >= 1
    }

    /// Where to dock a newcomer whose OS-assigned rect overlaps or floats free: flush
    /// to the nearest neighbor's edge without overlapping. nil ⇒ the OS spot already
    /// touches an edge cleanly — leave it.
    static func dockedOrigin(for newRect: CGRect, among others: [CGRect]) -> CGPoint? {
        guard !others.isEmpty else { return nil }
        let overlaps = others.contains { $0.insetBy(dx: 1, dy: 1).intersects(newRect.insetBy(dx: 1, dy: 1)) }
        let touches = others.contains { edgeAdjacent($0, newRect) }
        if touches && !overlaps { return nil }

        var best = newRect.origin; var bestDist = CGFloat.greatestFiniteMagnitude
        for r in others {
            for cand in [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX - newRect.width, y: r.minY),
                         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY - newRect.height)] {
                let placed = CGRect(origin: cand, size: newRect.size).insetBy(dx: 1, dy: 1)
                if others.contains(where: { $0.intersects(placed) }) { continue }
                let dist = hypot(cand.x - newRect.minX, cand.y - newRect.minY)
                if dist < bestDist { bestDist = dist; best = cand }
            }
        }
        return best
    }
}
