import XCTest
@testable import ScreenQueen

final class CalibrationMathTests: XCTestCase {

    func testSeamEdgePicksTheFacingEdge() {
        let v = SchematicLayout.Seam(vertical: true, line: 1000, lo: 0, hi: 800)
        XCTAssertEqual(CalibrationMath.seamEdge(v, selfIsA: true), .right)
        XCTAssertEqual(CalibrationMath.seamEdge(v, selfIsA: false), .left)
        let h = SchematicLayout.Seam(vertical: false, line: 800, lo: 0, hi: 1000)
        XCTAssertEqual(CalibrationMath.seamEdge(h, selfIsA: true), .bottom)
        XCTAssertEqual(CalibrationMath.seamEdge(h, selfIsA: false), .top)
    }

    func testReferenceIsASidesMatchSeamConvention() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let seam = SchematicLayout.seam(a, b)!
        XCTAssertTrue(CalibrationMath.referenceIsA(seam, a))
        XCTAssertFalse(CalibrationMath.referenceIsA(seam, b))
    }

    func testBarRectHugsItsEdgeCenteredOnAlongPlusOffset() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r = CalibrationMath.barRect(length: 300, offset: 20, thickness: 26,
                                        anchor: BarPlacement(edge: .bottom, along: 500), in: bounds)
        XCTAssertEqual(r.midX, 520)
        XCTAssertEqual(r.minY, CalibrationMath.barEdgeInset)
        XCTAssertEqual(r.size, CGSize(width: 300, height: 26))

        let right = CalibrationMath.barRect(length: 300, offset: 0, thickness: 26,
                                            anchor: BarPlacement(edge: .right, along: 400), in: bounds)
        XCTAssertEqual(right.maxX, 1000 - CalibrationMath.barEdgeInset)
        XCTAssertEqual(right.midY, 400)
        XCTAssertEqual(right.size, CGSize(width: 26, height: 300))
    }

    func testAxisPitches() {
        let p = CalibrationMath.axisPitches(bounds: CGRect(x: 0, y: 0, width: 2540, height: 1270),
                                            sizeMM: CGSize(width: 508, height: 254))!
        XCTAssertEqual(p.x, 127, accuracy: 1e-9)   // 2540pt over 20in
        XCTAssertEqual(p.y, 127, accuracy: 1e-9)
        XCTAssertNil(CalibrationMath.axisPitches(bounds: CGRect(x: 0, y: 0, width: 2540, height: 1270),
                                                 sizeMM: .zero))
    }

    // MARK: - Session plan

    private func snap(_ id: CGDirectDisplayID, _ bounds: CGRect, mm: CGSize,
                      edidMM: CGSize = .zero, builtin: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, name: "d\(id)", bounds: bounds,
            pixelSize: CGSize(width: bounds.width, height: bounds.height),
            physicalSizeMM: mm, physicalSizeIsCalibrated: false, edidSizeMM: edidMM,
            isMain: builtin, isBuiltin: builtin, vendor: 0, model: 0, serial: 0,
            refreshHz: 60
        )
    }

    /// Side-by-side pair: the primary tapes face the seam (ref right, target left);
    /// the pitches come from the trusted physical size vs. the target's EDID claim,
    /// and `k` is the suspect's claimed aspect.
    func testSessionPlanSideBySide() {
        // Trusted: 2540×1270 pt on a true 20×10 in panel → 127 pt/in each axis.
        let reference = snap(1, CGRect(x: 0, y: 0, width: 2540, height: 1270),
                             mm: CGSize(width: 508, height: 254))
        // Suspect: 1920×1080 pt, claims 24×13.5 in over EDID → 80 pt/in each axis.
        let target = snap(2, CGRect(x: 2540, y: 0, width: 1920, height: 1080),
                          mm: .zero, edidMM: CGSize(width: 609.6, height: 342.9))
        let plan = CalibrationMath.sessionPlan(
            reference: reference, target: target,
            refScreenSize: CGSize(width: 2540, height: 1270),
            targetScreenSize: CGSize(width: 1920, height: 1080),
            refPPT: 127)

        XCTAssertEqual(plan.refPrimary.anchor.edge, .right)
        XCTAssertEqual(plan.targetPrimary.anchor.edge, .left)
        XCTAssertEqual(plan.refPerp.anchor.edge, .bottom)     // external: desk convention
        XCTAssertEqual(plan.targetPerp.anchor.edge, .bottom)

        XCTAssertEqual(plan.refPrimary.pitch, 127, accuracy: 1e-9)   // y axis (vertical seam)
        XCTAssertEqual(plan.targetPrimary.pitch, 80, accuracy: 1e-6)
        XCTAssertEqual(plan.k, 24.0 / 13.5, accuracy: 1e-9)          // claimed width : height

        // The target starts at 90% of her primary edge, measured in her own inches.
        XCTAssertEqual(plan.targetPrimary.length, 0.9 * 1080, accuracy: 1e-6)
        XCTAssertEqual(plan.targetMeasure, 0.9 * 1080 / 80, accuracy: 1e-6)
    }

    /// The load-bearing link invariant: on both screens, perp/primary physical
    /// length is exactly `k`, so matching either same-axis pair implies the same
    /// scale — no measurement error from mixing.
    func testSessionPlanPairsShareTheAspectLink() {
        let reference = snap(1, CGRect(x: 0, y: 0, width: 1710, height: 1107),
                             mm: CGSize(width: 326.5714, height: 211.412), builtin: true)
        let target = snap(2, CGRect(x: 1710, y: 0, width: 1920, height: 1080),
                          mm: .zero, edidMM: CGSize(width: 596, height: 335))
        let plan = CalibrationMath.sessionPlan(
            reference: reference, target: target,
            refScreenSize: CGSize(width: 1710, height: 1107),
            targetScreenSize: CGSize(width: 1920, height: 1080),
            refPPT: 1710 / (326.5714 / 25.4))

        // Built-in reference: its perpendicular tape hugs the TOP (laptop on the desk).
        XCTAssertEqual(plan.refPerp.anchor.edge, .top)

        let refRatio = (Double(plan.refPerp.length) / plan.refPerp.pitch)
            / (Double(plan.refPrimary.length) / plan.refPrimary.pitch)
        let targetRatio = (Double(plan.targetPerp.length) / plan.targetPerp.pitch)
            / (Double(plan.targetPrimary.length) / plan.targetPrimary.pitch)
        XCTAssertEqual(refRatio, plan.k, accuracy: 1e-9)
        XCTAssertEqual(targetRatio, plan.k, accuracy: 1e-9)
    }

    func testInferredSizeScalesTheClaimedShape() {
        let size = CalibrationMath.inferredSize(claimed: CGSize(width: 24, height: 13.5),
                                                refMeasure: 10, targetMeasure: 8)!
        XCTAssertEqual(size.width, 30, accuracy: 1e-9)
        XCTAssertEqual(size.height, 16.875, accuracy: 1e-9)
        XCTAssertNil(CalibrationMath.inferredSize(claimed: CGSize(width: 24, height: 13.5),
                                                  refMeasure: 0, targetMeasure: 8))
        XCTAssertNil(CalibrationMath.inferredSize(claimed: .zero, refMeasure: 10, targetMeasure: 8))
    }
}
