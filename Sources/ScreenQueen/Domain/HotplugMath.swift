import CoreGraphics

/// The pure geometry/set rules behind hotplug handling (`AppDelegate+Hotplug`):
/// whether a point arrangement is valid, whether two rects touch edge-to-edge,
/// whether a newcomer is an identical twin of a present monitor, and where to dock
/// a newcomer. Framework-free and tested — this is the code most likely to silently
/// scramble someone's monitors.
enum HotplugMath {

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
