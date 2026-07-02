import CoreGraphics

/// Per-*seam* color assignment as a pure graph problem. Color belongs to a seam (a shared
/// edge between two displays), not to a monitor: both bars for a seam render in the seam's
/// color. This type only decides each seam's *palette index* (an edge-coloring); mapping an
/// index to an actual color is a presentation concern, done in the UI.
enum DisplayGraph {

    /// A seam's stable identity: the unordered pair of display ids it joins.
    struct SeamKey: Hashable {
        let a: CGDirectDisplayID, b: CGDirectDisplayID
        init(_ x: CGDirectDisplayID, _ y: CGDirectDisplayID) { a = min(x, y); b = max(x, y) }
    }

    /// Greedily edge-color the seams so two seams meeting at the same monitor never share a
    /// palette index (a proper edge-coloring). Seams are processed in a stable order (by
    /// their id pair) so indices don't churn while dragging.
    ///
    /// `previous` carries the last assignment so a surviving seam *keeps its color* when the
    /// tree rebuilds (a monitor plugged/unplugged elsewhere). A seam only recolors if its old
    /// index now conflicts with a higher-priority surviving seam at a shared monitor; new
    /// seams (and those bumped by a conflict) take the lowest free index at their monitors.
    static func seamColorIndices(_ seams: [(CGDirectDisplayID, CGDirectDisplayID)],
                                 previous: [SeamKey: Int] = [:]) -> [SeamKey: Int] {
        let keys = Array(Set(seams.map { SeamKey($0.0, $0.1) })).sorted {
            $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b
        }
        var colorIndexOf: [SeamKey: Int] = [:]
        // The color indices already used by seams incident to a given monitor.
        var usedAt: [CGDirectDisplayID: Set<Int>] = [:]

        func claim(_ key: SeamKey, _ idx: Int) {
            colorIndexOf[key] = idx
            usedAt[key.a, default: []].insert(idx)
            usedAt[key.b, default: []].insert(idx)
        }

        // Pass 1 — preserve: in stable order (so ties resolve deterministically toward the
        // lower-sorted seam), let each surviving seam keep its previous index if it's still
        // free at both its monitors. A seam that can't keep it falls through to pass 2.
        for key in keys {
            guard let prev = previous[key] else { continue }
            let taken = usedAt[key.a, default: []].union(usedAt[key.b, default: []])
            if !taken.contains(prev) { claim(key, prev) }
        }

        // Pass 2 — assign: seams still uncolored (new, or bumped in pass 1) take the lowest
        // free index at their monitors, again in stable order.
        for key in keys where colorIndexOf[key] == nil {
            let taken = usedAt[key.a, default: []].union(usedAt[key.b, default: []])
            var idx = 0
            while taken.contains(idx) { idx += 1 }
            claim(key, idx)
        }
        return colorIndexOf
    }
}
