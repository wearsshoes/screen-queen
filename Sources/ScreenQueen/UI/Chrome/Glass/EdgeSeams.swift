import SwiftUI

/// The seam system's on-glass half: full-screen bars hugging *this* screen's real
/// edges — the physical depiction of a window's size jump crossing the seam, in the
/// window's own point space (vs. the mini-map bars' tile space, Stage+TileSeams;
/// the shared glow/emitter engine is Seams/SeamEngine.swift).
extension Stage {

    /// The full-screen bars hugging *this* screen's real edges — the on-glass depiction
    /// of a window's size jump crossing the seam.
    func edgeBarEdges(_ bars: [SeamBar],
                      seamColor: [DisplayGraph.SeamKey: NSColor]) -> [SeamEdgeGlow] {
        guard let me = centerID else { return [] }
        let mine = displays.first { $0.id == me }
        // Constant *physical* thickness: convert inches → points via this screen's density.
        let thicknessInches: CGFloat = 0.08
        let thickness: CGFloat = mine?.pointsPerInch.map { thicknessInches * CGFloat($0) } ?? 9
        // Bar offsets/lengths are in *previewed* point space but drawn against the real
        // window bounds — scale them across, or spacing drifts during a zoom preview.
        let previewed = mine.map { model.pointSize($0) }
        var edges: [SeamEdgeGlow] = []
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let axisPreview = bar.isVertical ? (previewed?.height ?? bounds.height)
                                             : (previewed?.width ?? bounds.width)
            let axisReal = bar.isVertical ? bounds.height : bounds.width
            let s = axisPreview > 0 ? axisReal / axisPreview : 1
            let along = (weAreA ? bar.localAlongA : bar.localAlongB) * s
            let len = trimmedBarLength(bar.windowPoints * s, cap: 12)
            let rect: NSRect
            // `inward` = the side facing the screen center (rounded); outward sits flat.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                // `along` is y-down from the screen top, same as the view.
                rect = NSRect(x: x, y: along - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX
            } else {
                let y = weAreA ? bounds.height - thickness : 0   // a = above the seam
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .minY : .maxY
            }
            edges.append(SeamEdgeGlow(rect: rect, inward: inward, color: facing))
        }
        return edges
    }
}
