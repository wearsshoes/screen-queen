import AppKit
import CoreGraphics

/// Per-*seam* palette assignment. Color belongs to a seam (a shared edge between two
/// displays), not to a monitor: both bars for a seam — the on-glass edge bars on each
/// participating screen and the mini-map reference bars — render in the seam's color.
enum DisplayGraph {

    static let palette: [NSColor] = [
        .systemPink, .systemGreen, .systemBlue, .systemOrange,
        .systemPurple, .systemTeal, .systemYellow, .systemRed
    ]

    /// A seam's stable identity: the unordered pair of display ids it joins.
    struct SeamKey: Hashable {
        let a: CGDirectDisplayID, b: CGDirectDisplayID
        init(_ x: CGDirectDisplayID, _ y: CGDirectDisplayID) { a = min(x, y); b = max(x, y) }
    }

    /// Greedily edge-color the seams so two seams meeting at the same monitor never
    /// share a color (a proper edge-coloring). Seams are processed in a stable order
    /// (by their id pair) so colors don't churn while dragging.
    static func seamColors(_ seams: [(CGDirectDisplayID, CGDirectDisplayID)]) -> [SeamKey: NSColor] {
        let keys = Array(Set(seams.map { SeamKey($0.0, $0.1) })).sorted {
            $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b
        }
        var colorIndexOf: [SeamKey: Int] = [:]
        // The color indices already used by seams incident to a given monitor.
        var usedAt: [CGDirectDisplayID: Set<Int>] = [:]
        for key in keys {
            let taken = usedAt[key.a, default: []].union(usedAt[key.b, default: []])
            var idx = 0
            while taken.contains(idx) { idx += 1 }
            colorIndexOf[key] = idx
            usedAt[key.a, default: []].insert(idx)
            usedAt[key.b, default: []].insert(idx)
        }
        return colorIndexOf.mapValues { palette[$0 % palette.count] }
    }
}
