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

    // MARK: - Presence (chrome real ↔ ghost crossfade)

    func testPresenceEndpointsAndMonotonicity() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // On the screen (any point inside): fully present.
        XCTAssertEqual(VirtualMouse.presence(cursor: CGPoint(x: 5, y: 5), screenBounds: screen), 1)
        XCTAssertEqual(VirtualMouse.presence(cursor: CGPoint(x: 1919, y: 1079), screenBounds: screen), 1)
        // At/beyond the threshold: fully ghost.
        let far = CGPoint(x: 1920 + VirtualMouse.presenceThreshold, y: 540)
        XCTAssertEqual(VirtualMouse.presence(cursor: far, screenBounds: screen), 0)
        // Approach is monotonic: closer ⇒ more present.
        var last: CGFloat = -1
        for d in stride(from: VirtualMouse.presenceThreshold, through: 0, by: -20) {
            let p = VirtualMouse.presence(cursor: CGPoint(x: 1920 + d, y: 540), screenBounds: screen)
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
        XCTAssertEqual(last, 1)
        // Degenerate screens contribute nothing.
        XCTAssertEqual(VirtualMouse.presence(cursor: .zero, screenBounds: .zero), 0)
    }

    func testSmoothstepClampsAndEases() {
        XCTAssertEqual(VirtualMouse.smoothstep(-1), 0)
        XCTAssertEqual(VirtualMouse.smoothstep(0), 0)
        XCTAssertEqual(VirtualMouse.smoothstep(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VirtualMouse.smoothstep(1), 1)
        XCTAssertEqual(VirtualMouse.smoothstep(2), 1)
    }

    // MARK: - Cross-canvas projection (the one mapping the ghost rides everywhere)

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
        // which is what makes a projected chrome rect stay a rect — and means the
        // arrow can never "snap": equal cursor steps are equal ghost steps.
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
