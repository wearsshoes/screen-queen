import CoreGraphics
import XCTest
@testable import ScreenQueen

/// The virtual-mouse math and the revert policy: the beacon's cursor→plane mapping,
/// the ghost's view↔plane inverse pair, and "did every display change at once".
@MainActor
final class VirtualMouseTests: XCTestCase {

    // MARK: - Transform.planePoint ↔ viewPoint (the ghost's plane hop)

    func testTransformPlanePointInvertsViewPoint() {
        let t = Arranger.Transform(scale: 12.5, offset: CGPoint(x: 137, y: 42),
                                   unionOrigin: CGPoint(x: -3.5, y: 7.25), viewHeight: 900)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 10.5, y: -4.2),
                  CGPoint(x: -3.5, y: 7.25), CGPoint(x: 61.7, y: 33.3)] {
            let round = t.planePoint(t.viewPoint(p))
            XCTAssertEqual(round.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(round.y, p.y, accuracy: 1e-9)
        }
        // And the other direction, starting from view space.
        for v in [CGPoint(x: 0, y: 900), CGPoint(x: 512, y: 384), CGPoint(x: 137, y: 42)] {
            let round = t.viewPoint(t.planePoint(v))
            XCTAssertEqual(round.x, v.x, accuracy: 1e-9)
            XCTAssertEqual(round.y, v.y, accuracy: 1e-9)
        }
    }

    // MARK: - VirtualMouse.planePoint (the beacon's cursor→plane hop)

    func testCursorFractionTransfersToPlaneRect() {
        // A 1920×1080 display whose plane rect is 23.5″×13.2″ at (10, 5) inches.
        let bounds = CGRect(x: 1710, y: -549, width: 1920, height: 1080)
        let plane = CGRect(x: 10, y: 5, width: 23.5, height: 13.2)

        // Top-left corner → top-left of the plane rect (both spaces are y-down).
        let tl = VirtualMouse.planePoint(cursor: CGPoint(x: 1710, y: -549),
                                         displayBounds: bounds, planeRect: plane)
        XCTAssertEqual(tl?.x ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(tl?.y ?? -1, 5, accuracy: 1e-9)

        // Center → center.
        let mid = VirtualMouse.planePoint(cursor: CGPoint(x: bounds.midX, y: bounds.midY),
                                          displayBounds: bounds, planeRect: plane)
        XCTAssertEqual(mid?.x ?? -1, plane.midX, accuracy: 1e-9)
        XCTAssertEqual(mid?.y ?? -1, plane.midY, accuracy: 1e-9)

        // A quarter across, three quarters down — the y fraction must not flip.
        let q = VirtualMouse.planePoint(cursor: CGPoint(x: 1710 + 480, y: -549 + 810),
                                        displayBounds: bounds, planeRect: plane)
        XCTAssertEqual(q?.x ?? -1, 10 + 23.5 * 0.25, accuracy: 1e-9)
        XCTAssertEqual(q?.y ?? -1, 5 + 13.2 * 0.75, accuracy: 1e-9)

        // Degenerate bounds can't produce a fraction.
        XCTAssertNil(VirtualMouse.planePoint(cursor: .zero,
                                             displayBounds: CGRect(x: 0, y: 0, width: 0, height: 1080),
                                             planeRect: plane))
    }

    // MARK: - RevertPolicy (when the auto-revert countdown arms)

    func testCoversEveryDisplay() {
        XCTAssertTrue(RevertPolicy.coversEveryDisplay(changed: [1, 2, 3], all: [1, 2, 3]))
        XCTAssertTrue(RevertPolicy.coversEveryDisplay(changed: [1, 2, 3], all: [1, 2]),
                      "extra changed ids (a display that vanished mid-flight) still cover")
        XCTAssertTrue(RevertPolicy.coversEveryDisplay(changed: [7], all: [7]),
                      "a single-display setup counts by construction")
        XCTAssertFalse(RevertPolicy.coversEveryDisplay(changed: [1, 2], all: [1, 2, 3]),
                       "a partial change leaves a live screen — no countdown")
        XCTAssertFalse(RevertPolicy.coversEveryDisplay(changed: [], all: []),
                       "no displays, no countdown")
    }
}
