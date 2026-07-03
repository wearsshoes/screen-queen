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
