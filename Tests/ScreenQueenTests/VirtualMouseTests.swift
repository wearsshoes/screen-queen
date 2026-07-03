import CoreGraphics
import XCTest
@testable import ScreenQueen

/// The ghost-chrome projection math and the revert policy: the plane↔view inverse
/// pair the projection rides, its affinity, the bar width cap, and "did every display
/// change at once".
@MainActor
final class VirtualMouseTests: XCTestCase {

    // MARK: - Transform.planePoint ↔ viewPoint (the plane hop the projection rides)

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

    // MARK: - Cross-canvas projection (the mapping every ghost image rides)

    func testHostToDestProjectionIsContinuousAndInvertible() {
        // Two canvases over the same plane at different scales/offsets — the shape of
        // two differently-sized screens showing the same schematic.
        let hostT = Arranger.Transform(scale: 20, offset: CGPoint(x: 400, y: 300),
                                       unionOrigin: CGPoint(x: -2, y: 1), viewHeight: 1864)
        let destT = Arranger.Transform(scale: 12, offset: CGPoint(x: 250, y: 180),
                                       unionOrigin: CGPoint(x: -2, y: 1), viewHeight: 1080)
        func project(_ p: CGPoint) -> CGPoint { destT.viewPoint(hostT.planePoint(p)) }
        // Invertible: host → dest → host is exact.
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 96), CGPoint(x: 2879, y: 1863)] {
            let back = hostT.viewPoint(destT.planePoint(project(p)))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
        // Affine (scale + translate): distances scale uniformly by destScale/hostScale,
        // which is what makes a projected chrome rect stay a rect — a source control's
        // box projects to a box on every other canvas.
        let a = project(CGPoint(x: 100, y: 100)), b = project(CGPoint(x: 200, y: 100))
        let c = project(CGPoint(x: 1000, y: 900)), d = project(CGPoint(x: 1100, y: 900))
        XCTAssertEqual(b.x - a.x, d.x - c.x, accuracy: 1e-9)
        XCTAssertEqual(b.x - a.x, 100 * 12 / 20, accuracy: 1e-9)
    }

    // MARK: - Bar width cap (the never-out-of-bounds rule)

    func testBarWidthCap() {
        XCTAssertEqual(Arranger.barWidthCap(minScreenWidth: 1920), 1856)
        XCTAssertEqual(Arranger.barWidthCap(minScreenWidth: 1080), 1016, "rotated 1080p never compresses the bar")
        XCTAssertEqual(Arranger.barWidthCap(minScreenWidth: 300), 320, "floored below the brawl line")
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
