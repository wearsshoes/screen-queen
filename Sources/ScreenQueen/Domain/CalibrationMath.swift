import CoreGraphics

/// Where a calibration tape sits on the screen it's drawn on: which edge it hugs and its
/// center offset from that screen's leading edge along that edge's axis.
struct BarPlacement {
    enum Edge { case left, right, top, bottom }
    let edge: Edge
    let along: CGFloat          // center along the edge, in this screen's local (y-up) frame

    /// A vertical edge runs the tape vertically; horizontal runs it across.
    var lengthIsVertical: Bool { edge == .left || edge == .right }
}

/// Pure calibration geometry + the size inference. No AppKit views, no windows —
/// just the math shared by the calibration overlay.
enum CalibrationMath {

    /// Distance a tape is inset from the screen edge it hugs, so it reads as a floating
    /// control rather than glued to the bezel.
    static let barEdgeInset: CGFloat = 22

    /// Whether `bounds` is on the a-side of `seam` (left for a vertical seam, top for a
    /// horizontal one), matching `Seam`'s a = left/top convention.
    static func referenceIsA(_ seam: SchematicLayout.Seam, _ bounds: CGRect) -> Bool {
        seam.vertical ? abs(bounds.maxX - seam.line) < 1 : abs(bounds.maxY - seam.line) < 1
    }

    /// The screen edge facing the other display across `seam`, where `selfIsA` picks
    /// this screen's side (a = left/top).
    static func seamEdge(_ seam: SchematicLayout.Seam, selfIsA: Bool) -> BarPlacement.Edge {
        seam.vertical ? (selfIsA ? .right : .left) : (selfIsA ? .bottom : .top)
    }

    /// Rect for a tape of `length` hugging its placement edge; `offset` slides the tape's
    /// center along the edge from its anchor, `thickness` sets its cross size.
    static func barRect(length: CGFloat, offset: CGFloat, thickness t: CGFloat,
                        anchor a: BarPlacement, in bounds: CGRect) -> CGRect {
        let along = a.along + offset
        let inset = barEdgeInset
        switch a.edge {
        case .right:  return CGRect(x: bounds.maxX - t - inset, y: along - length / 2, width: t, height: length)
        case .left:   return CGRect(x: bounds.minX + inset,     y: along - length / 2, width: t, height: length)
        case .top:    return CGRect(x: along - length / 2, y: bounds.maxY - t - inset, width: length, height: t)
        case .bottom: return CGRect(x: along - length / 2, y: bounds.minY + inset,     width: length, height: t)
        }
    }

    /// The perpendicular-tape edge for a display that isn't constrained by a seam:
    /// the bottom by convention, but a built-in laptop panel uses its top — the
    /// laptop is on the desk, so its top edge is the one living near the monitor.
    static func deskEdge(isBuiltin: Bool) -> BarPlacement.Edge {
        isBuiltin ? .top : .bottom
    }

    /// The edge for a display's second tape, perpendicular to its primary. For a
    /// vertical primary (side-by-side displays) that's the desk convention above;
    /// for a horizontal primary (stacked displays) both screens use the left edge
    /// so the pair can still be sighted across the gap.
    static func perpendicularEdge(to primary: BarPlacement.Edge, isBuiltin: Bool) -> BarPlacement.Edge {
        switch primary {
        case .left, .right: return deskEdge(isBuiltin: isBuiltin)
        case .top, .bottom: return .left
        }
    }

    /// A placement hugging `edge` and centered on it, plus that edge's full extent
    /// in the screen's points — the tape's starting length.
    static func fullEdgePlacement(_ edge: BarPlacement.Edge, screenSize size: CGSize) -> (BarPlacement, CGFloat) {
        let vertical = edge == .left || edge == .right
        let extent = vertical ? size.height : size.width
        return (BarPlacement(edge: edge, along: extent / 2), extent)
    }

    /// Per-axis points-per-inch for a `bounds`-point screen of physical size `sizeMM`,
    /// or nil when the physical size is missing or implausible.
    static func axisPitches(bounds: CGRect, sizeMM: CGSize) -> (x: Double, y: Double)? {
        let w = Double(sizeMM.width) / 25.4, h = Double(sizeMM.height) / 25.4
        guard w > 0.5, h > 0.5 else { return nil }
        return (x: Double(bounds.width) / w, y: Double(bounds.height) / h)
    }

    /// The target's physical size in inches: her claimed (EDID) shape scaled by the one
    /// number the match determines — how many true inches her "inch" actually is. Every
    /// matched pairing of tapes yields this same factor, which is the point: one
    /// measurement per screen, nothing to disagree. Nil when undetermined.
    static func inferredSize(claimed: CGSize, refMeasure: Double, targetMeasure: Double) -> CGSize? {
        guard refMeasure > 0, targetMeasure > 0, claimed.width > 0, claimed.height > 0 else { return nil }
        let scale = refMeasure / targetMeasure
        return CGSize(width: claimed.width * scale, height: claimed.height * scale)
    }
}
