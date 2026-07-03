import SwiftUI

/// The seam system's map half: the mini-map reference bars, in tile space — the
/// reference window shown on each side of a seam at its own physical size (the size
/// jump a window makes crossing it). The on-glass half lives in Chrome/EdgeSeams.swift;
/// the shared glow/emitter engine in Seams/SeamEngine.swift.
extension Stage {

    /// The mini-map bars: two per seam (one each side), D-shaped, flush to the seam,
    /// rounding toward the owning display's center.
    func miniBarEdges(_ bars: [SeamBar], t: Transform,
                      seamColor: [DisplayGraph.SeamKey: NSColor]) -> [SeamEdgeGlow] {
        let thickness: CGFloat = 5, gap: CGFloat = 2
        // Trim the ends clear of the rounded corners.
        func barLen(_ inches: CGFloat) -> CGFloat { trimmedBarLength(inches * t.scale, cap: 8) }
        var edges: [SeamEdgeGlow] = []
        for bar in bars {
            let color = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let lenA = barLen(bar.physLenInchesA)
            let lenB = barLen(bar.physLenInchesB)
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                // a = left display: its bar hugs the seam and rounds toward its center.
                edges.append(SeamEdgeGlow(rect: NSRect(x: cA.x - gap - thickness, y: cA.y - lenA / 2, width: thickness, height: lenA), inward: .minX, color: color))
                edges.append(SeamEdgeGlow(rect: NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB), inward: .maxX, color: color))
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                // a = top display: its bar sits above the seam and rounds toward its center.
                edges.append(SeamEdgeGlow(rect: NSRect(x: cA.x - lenA / 2, y: cA.y - gap - thickness, width: lenA, height: thickness), inward: .minY, color: color))
                edges.append(SeamEdgeGlow(rect: NSRect(x: cB.x - lenB / 2, y: cB.y + gap, width: lenB, height: thickness), inward: .maxY, color: color))
            }
        }
        return edges
    }
}
