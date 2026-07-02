import CoreGraphics

/// Where a calibration bar sits on the screen it's drawn on: which edge it abuts and its
/// center offset from that screen's leading edge along the seam axis. Derived from
/// `SchematicLayout.Seam` so calibration and the arranger place bars from the same source.
struct BarPlacement {
    enum Edge { case left, right, top, bottom }
    let edge: Edge
    let along: CGFloat          // center along the seam, in this screen's local (view) frame

    /// A vertical seam (left/right edge) runs the bar vertically; horizontal runs it across.
    var lengthIsVertical: Bool { edge == .left || edge == .right }

    /// A placement stated directly: hug `edge`, centered at `along` in the
    /// screen's local (y-up) frame. For bars that aren't tied to a seam overlap —
    /// e.g. a tape spanning a full screen edge.
    init(edge: Edge, along: CGFloat) {
        self.edge = edge
        self.along = along
    }

    /// The bar's placement on `frame` for the seam `s` shared with a neighbor, where
    /// `selfIsA` picks this screen's side (a = left/top). `SchematicLayout.Seam` is in the
    /// OS's y-down space; the drawing frame is y-up, so a vertical seam's along-center is
    /// mirrored within the screen height.
    init(seam s: SchematicLayout.Seam, screen frame: CGRect, selfIsA: Bool) {
        let along = s.localCenter(on: frame)
        if s.vertical {
            edge = selfIsA ? .right : .left
            self.along = frame.height - along
        } else {
            edge = selfIsA ? .bottom : .top        // a is on top (CG maxY == b.minY)
            self.along = along
        }
    }
}

/// Pure calibration geometry + the PPI-from-matched-bars inference. No AppKit views, no
/// windows — just the math shared by the calibration overlay.
enum CalibrationMath {

    /// Distance a bar is inset from the screen edge it hugs, so it reads as a floating
    /// control rather than glued to the bezel.
    static let barEdgeInset: CGFloat = 22

    /// Whether `bounds` is on the a-side of `seam` (left for a vertical seam, top for a
    /// horizontal one), matching `Seam`'s a = left/top convention.
    static func referenceIsA(_ seam: SchematicLayout.Seam, _ bounds: CGRect) -> Bool {
        seam.vertical ? abs(bounds.maxX - seam.line) < 1 : abs(bounds.maxY - seam.line) < 1
    }

    /// Rect for a bar of `length`, hugging an optional seam placement (or a horizontal bar
    /// centered in `bounds` when there's no seam). `offset` slides the bar's center along
    /// the seam from its anchor; `thickness` sets its cross size.
    static func barRect(length: CGFloat, offset: CGFloat, thickness t: CGFloat,
                        anchor: BarPlacement?, in bounds: CGRect) -> CGRect {
        guard let a = anchor else {
            return CGRect(x: bounds.midX - length / 2, y: bounds.midY - t / 2, width: length, height: t)
        }
        let along = a.along + offset
        let inset = barEdgeInset
        switch a.edge {
        case .right:  return CGRect(x: bounds.maxX - t - inset, y: along - length / 2, width: t, height: length)
        case .left:   return CGRect(x: bounds.minX + inset,     y: along - length / 2, width: t, height: length)
        case .top:    return CGRect(x: along - length / 2, y: bounds.maxY - t - inset, width: length, height: t)
        case .bottom: return CGRect(x: along - length / 2, y: bounds.minY + inset,     width: length, height: t)
        }
    }

    /// The target PPI implied by two matched bar lengths: the reference bar's known
    /// physical length (points ÷ trusted PPI) equals the target bar's, so
    /// `ppi_target = targetPoints / (refPoints / refPPI)`. 0 when undetermined.
    static func inferredTargetPPI(refLengthPoints: CGFloat, refPPI: Double,
                                  targetLengthPoints: CGFloat) -> Double {
        let refInches = Double(refLengthPoints) / refPPI
        return refInches > 0 ? Double(targetLengthPoints) / refInches : 0
    }

    /// Physical diagonal (inches) of a `pointSize` panel at `ppi`. 0 when undetermined.
    static func diagonalInches(pointSize: CGSize, ppi: Double) -> Double {
        guard ppi > 0 else { return 0 }
        let w = Double(pointSize.width), h = Double(pointSize.height)
        return (w * w + h * h).squareRoot() / ppi
    }
}
