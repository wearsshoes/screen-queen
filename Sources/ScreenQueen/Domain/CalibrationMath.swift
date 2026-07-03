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

    // MARK: - The session plan (everything `begin` stages, computed purely)

    /// One tape's staging: starting length (points), the edge it hugs, and the pitch
    /// its ribbon is ruled at.
    struct TapeSpec {
        let length: CGFloat
        let anchor: BarPlacement
        let pitch: Double
    }

    /// The staged math for a match-calibration session: which edge each of the four
    /// tapes hugs, its starting length and ruling pitch, the aspect link `k`, and the
    /// starting measures. Pure — the controller only builds tapes from it.
    struct SessionPlan {
        let refPrimary: TapeSpec, refPerp: TapeSpec
        let targetPrimary: TapeSpec, targetPerp: TapeSpec
        /// Perp:primary physical ratio (the SUSPECT's claimed aspect) — identical on
        /// both screens, so matching either same-axis pair implies the same scale.
        let k: Double
        let refMeasure: Double          // trusted screen's starting measure, true inches
        let targetMeasure: Double       // target's starting measure, her claimed inches
        let targetClaimedSize: CGSize   // her EDID story, in inches
        let targetFull: CGFloat         // the target's primary edge extent (points)
        let targetPerpFull: CGFloat
    }

    static func sessionPlan(reference: DisplaySnapshot, target: DisplaySnapshot,
                            refScreenSize: CGSize, targetScreenSize: CGSize,
                            refPPT: Double) -> SessionPlan {
        // The seam picks each screen's *edge* facing the other display; it doesn't
        // cap the tape, which spans that full edge. Without a seam (non-adjacent),
        // fall back to the perpendicular-edge convention for the primary too.
        let seam = SchematicLayout.seam(reference.bounds, target.bounds)
        let refIsA = seam.map { referenceIsA($0, reference.bounds) } ?? true
        let refEdge = seam.map { seamEdge($0, selfIsA: refIsA) }
            ?? deskEdge(isBuiltin: reference.isBuiltin)
        let targetEdge = seam.map { seamEdge($0, selfIsA: !refIsA) }
            ?? deskEdge(isBuiltin: target.isBuiltin)

        // Two tapes per screen: the seam-facing edge, plus a perpendicular one —
        // the bottom by convention, except a laptop panel uses its top (the laptop
        // is on the desk; its top edge is the one near the monitor's bottom). Each
        // pair is an independent axis measurement.
        let (refPlace, refFull) = fullEdgePlacement(refEdge, screenSize: refScreenSize)
        let (refPerpPlace, refPerpFull) = fullEdgePlacement(
            perpendicularEdge(to: refEdge, isBuiltin: reference.isBuiltin), screenSize: refScreenSize)
        let (targetPlace, targetFull) = fullEdgePlacement(targetEdge, screenSize: targetScreenSize)
        let (targetPerpPlace, targetPerpFull) = fullEdgePlacement(
            perpendicularEdge(to: targetEdge, isBuiltin: target.isBuiltin), screenSize: targetScreenSize)

        // Per-axis pitches: the trusted screen's true points-per-inch, and the
        // pitch the target *claims* over EDID — shape trusted, scale on trial.
        // When she won't even claim a size, assume the trusted pitch.
        let refPitch = axisPitches(bounds: reference.bounds, sizeMM: reference.physicalSizeMM)
            ?? (x: refPPT, y: refPPT)
        let targetPitch: (x: Double, y: Double)
        let targetClaimedSize: CGSize
        if let claimed = axisPitches(bounds: target.bounds, sizeMM: target.edidSizeMM) {
            targetPitch = claimed
            targetClaimedSize = CGSize(width: Double(target.edidSizeMM.width) / 25.4,
                                       height: Double(target.edidSizeMM.height) / 25.4)
        } else {
            targetPitch = (x: refPPT, y: refPPT)
            targetClaimedSize = CGSize(width: Double(target.bounds.width) / refPPT,
                                       height: Double(target.bounds.height) / refPPT)
        }
        let primaryVertical = targetPlace.lengthIsVertical
        func pitch(_ p: (x: Double, y: Double), vertical: Bool) -> Double { vertical ? p.y : p.x }
        let refPrimaryPitch = pitch(refPitch, vertical: primaryVertical)
        let refPerpPitch = pitch(refPitch, vertical: !primaryVertical)
        let targetPrimaryPitch = pitch(targetPitch, vertical: primaryVertical)
        let targetPerpPitch = pitch(targetPitch, vertical: !primaryVertical)

        // Both screens link their pair at the SUSPECT's claimed aspect: the ratio
        // between perpendicular and primary physical lengths is `k` on both
        // sides, so matching either same-axis pair implies the same scale.
        let k = primaryVertical
            ? Double(targetClaimedSize.width) / Double(targetClaimedSize.height)
            : Double(targetClaimedSize.height) / Double(targetClaimedSize.width)

        // The suspect's tapes start at 90% of her own edges (her claimed aspect,
        // out of her corners). The trusted pair starts at 90% too, shrunk if the
        // k-linked perpendicular tape wouldn't fit its own edge.
        let f0 = 0.9
        let targetMeasure = f0 * Double(targetFull) / targetPrimaryPitch
        let refMeasure = min(f0 * Double(refFull) / refPrimaryPitch,
                             f0 * Double(refPerpFull) / refPerpPitch / k)

        return SessionPlan(
            refPrimary: TapeSpec(length: CGFloat(refMeasure * refPrimaryPitch),
                                 anchor: refPlace, pitch: refPrimaryPitch),
            refPerp: TapeSpec(length: CGFloat(refMeasure * k * refPerpPitch),
                              anchor: refPerpPlace, pitch: refPerpPitch),
            targetPrimary: TapeSpec(length: CGFloat(f0) * targetFull,
                                    anchor: targetPlace, pitch: targetPrimaryPitch),
            targetPerp: TapeSpec(length: CGFloat(f0) * targetPerpFull,
                                 anchor: targetPerpPlace, pitch: targetPerpPitch),
            k: k, refMeasure: refMeasure, targetMeasure: targetMeasure,
            targetClaimedSize: targetClaimedSize,
            targetFull: targetFull, targetPerpFull: targetPerpFull)
    }
}
