import CoreGraphics
import XCTest
@testable import ScreenQueen

/// The framework-free view geometry: the fit's invariants, chrome placement, the ghost
/// mapping, cursor→plane, and pixel snapping. (The Transform round-trip itself is
/// covered in VirtualMouseTests.)
final class ArrangerGeometryTests: XCTestCase {

    // MARK: - fit

    func testFitCentersTheUnionAtTheViewMidpoint() {
        let rects: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 24, height: 13.5),
            2: CGRect(x: 24, y: 2, width: 12, height: 20),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let t = ArrangerGeometry.fit(rects, in: bounds, padding: 32)!
        let union = rects.values.reduce(rects[1]!) { $0.union($1) }
        let centre = t.viewPoint(CGPoint(x: union.midX, y: union.midY))
        XCTAssertEqual(centre.x, bounds.midX, accuracy: 1e-9)
        XCTAssertEqual(centre.y, bounds.midY, accuracy: 1e-9)
    }

    func testFitNeverOverflowsThePadding() {
        // A wide arrangement that must be capped by the fit rule, not the 3-tiles target.
        let rects: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 24, height: 13.5),
            2: CGRect(x: 24, y: 0, width: 24, height: 13.5),
            3: CGRect(x: 48, y: 0, width: 24, height: 13.5),
            4: CGRect(x: 72, y: 0, width: 24, height: 13.5),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let padding: CGFloat = 32
        let t = ArrangerGeometry.fit(rects, in: bounds, padding: padding)!
        let union = rects.values.reduce(rects[1]!) { $0.union($1) }
        let view = t.viewRect(union)
        XCTAssertGreaterThanOrEqual(view.minX, padding - 1e-9)
        XCTAssertLessThanOrEqual(view.maxX, bounds.width - padding + 1e-9)
        XCTAssertGreaterThanOrEqual(view.minY, padding - 1e-9)
        XCTAssertLessThanOrEqual(view.maxY, bounds.height - padding + 1e-9)
    }

    func testFitTargetsThreeLargestTilesAcrossTheView() {
        // One display, plenty of room: the target rule wins — 3 tile widths span the
        // available width (the height constraint is looser for this landscape tile).
        let rects: [CGDirectDisplayID: CGRect] = [1: CGRect(x: 0, y: 0, width: 24, height: 13.5)]
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let padding: CGFloat = 32
        let t = ArrangerGeometry.fit(rects, in: bounds, padding: padding)!
        XCTAssertEqual(t.scale, (bounds.width - padding * 2) / (3 * 24), accuracy: 1e-9)
    }

    func testFitRejectsDegenerateInput() {
        XCTAssertNil(ArrangerGeometry.fit([:], in: CGRect(x: 0, y: 0, width: 100, height: 100), padding: 0))
        XCTAssertNil(ArrangerGeometry.fit([1: .zero], in: CGRect(x: 0, y: 0, width: 100, height: 100), padding: 0))
    }

    // MARK: - Chrome placement

    func testChromeViewRectCentresAtPlaneInchOffset() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let r = ArrangerGeometry.chromeViewRect(finalSize: CGSize(width: 200, height: 50),
                                                centreOffsetInches: CGPoint(x: 0, y: -10),
                                                bounds: bounds, scale: 17)
        XCTAssertEqual(r.midX, 500, accuracy: 1e-9)
        XCTAssertEqual(r.midY, 400 - 10 * 17, accuracy: 1e-9)   // 10 plane inches below centre
        XCTAssertEqual(r.size, CGSize(width: 200, height: 50))
    }

    // MARK: - Ghost mapping

    func testGhostPointIdentityWhenScalesMatch() {
        let p = CGPoint(x: 123.4, y: 567.8)
        let c = CGPoint(x: 500, y: 400)
        let out = ArrangerGeometry.ghostPoint(p, ghostScale: 1, activeCenter: c, destCenter: c)
        XCTAssertEqual(out.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(out.y, p.y, accuracy: 1e-9)
    }

    func testGhostPointScalesOffsetsFromTheCentre() {
        let active = CGPoint(x: 800, y: 600), dest = CGPoint(x: 400, y: 300)
        let out = ArrangerGeometry.ghostPoint(CGPoint(x: 900, y: 560),
                                              ghostScale: 0.5, activeCenter: active, destCenter: dest)
        XCTAssertEqual(out.x, 400 + 0.5 * 100, accuracy: 1e-9)
        XCTAssertEqual(out.y, 300 + 0.5 * -40, accuracy: 1e-9)
    }

    // MARK: - Cursor → plane

    func testPlanePointTransfersTheFraction() {
        let display = CGRect(x: 100, y: 50, width: 200, height: 100)
        let plane = CGRect(x: 10, y: 20, width: 24, height: 13.5)
        let out = ArrangerGeometry.planePoint(cursor: CGPoint(x: 200, y: 75),
                                              displayBounds: display, planeRect: plane)!
        XCTAssertEqual(out.x, 10 + 0.5 * 24, accuracy: 1e-9)     // halfway across
        XCTAssertEqual(out.y, 20 + 0.25 * 13.5, accuracy: 1e-9)  // a quarter down
    }

    func testPlanePointRejectsDegenerateBounds() {
        XCTAssertNil(ArrangerGeometry.planePoint(cursor: .zero, displayBounds: .zero,
                                                 planeRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    // MARK: - Pixel snapping

    func testPixelSnapRoundsToDevicePixels() {
        XCTAssertEqual(ArrangerGeometry.pixelSnap(10.3, backingScale: 2), 10.5)
        XCTAssertEqual(ArrangerGeometry.pixelSnap(10.2, backingScale: 2), 10.0)
        XCTAssertEqual(ArrangerGeometry.pixelSnap(10.4, backingScale: 1), 10.0)
        XCTAssertEqual(ArrangerGeometry.pixelSnap(10.6, backingScale: 1), 11.0)
    }
}
