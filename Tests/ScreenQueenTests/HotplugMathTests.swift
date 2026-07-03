import CoreGraphics
import XCTest
@testable import ScreenQueen

/// The pure hotplug rules — the code most likely to silently scramble someone's
/// monitors, so every branch gets a case.
final class HotplugMathTests: XCTestCase {

    private let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - edgeAdjacent

    func testEdgeAdjacency() {
        // Flush right neighbor with vertical overlap.
        XCTAssertTrue(HotplugMath.edgeAdjacent(a, CGRect(x: 1920, y: 200, width: 1440, height: 900)))
        // Flush top neighbor with horizontal overlap.
        XCTAssertTrue(HotplugMath.edgeAdjacent(a, CGRect(x: 500, y: 1080, width: 1440, height: 900)))
        // Corner-only contact (no overlap along either axis) doesn't count.
        XCTAssertFalse(HotplugMath.edgeAdjacent(a, CGRect(x: 1920, y: 1080, width: 100, height: 100)))
        // A gap wider than the tolerance doesn't count.
        XCTAssertFalse(HotplugMath.edgeAdjacent(a, CGRect(x: 1925, y: 0, width: 100, height: 100)))
    }

    // MARK: - arrangementIsValid

    func testArrangementValidity() {
        XCTAssertTrue(HotplugMath.arrangementIsValid([a]), "a solo display is trivially valid")
        let flush = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        XCTAssertTrue(HotplugMath.arrangementIsValid([a, flush]))
        // Overlap → invalid.
        XCTAssertFalse(HotplugMath.arrangementIsValid([a, CGRect(x: 1900, y: 0, width: 1440, height: 900)]))
        // Gap (disconnected) → invalid: the middle of three was removed.
        XCTAssertFalse(HotplugMath.arrangementIsValid([a, CGRect(x: 4000, y: 0, width: 1440, height: 900)]))
        // Three in a row, connected through the middle → valid.
        let mid = CGRect(x: 1920, y: 0, width: 1000, height: 1080)
        let right = CGRect(x: 2920, y: 100, width: 1440, height: 900)
        XCTAssertTrue(HotplugMath.arrangementIsValid([a, mid, right]))
    }

    // MARK: - joinedIdenticalTwin

    func testJoinedIdenticalTwin() {
        XCTAssertTrue(HotplugMath.joinedIdenticalTwin(now: ["dell", "dell"], before: ["dell"]))
        XCTAssertTrue(HotplugMath.joinedIdenticalTwin(now: ["mac", "dell", "dell"], before: ["mac", "dell"]))
        XCTAssertFalse(HotplugMath.joinedIdenticalTwin(now: ["mac", "lg"], before: ["mac"]),
                       "a *different* newcomer isn't a twin")
        XCTAssertFalse(HotplugMath.joinedIdenticalTwin(now: ["dell", "dell", "dell"], before: ["dell"]),
                       "growth by two isn't a single twin join")
        XCTAssertFalse(HotplugMath.joinedIdenticalTwin(now: ["dell"], before: ["dell"]),
                       "no growth, no twin")
    }

    // MARK: - dockedOrigin

    func testDockedOriginLeavesCleanPlacementsAlone() {
        // Already flush to the right edge, no overlap → nil (leave it).
        XCTAssertNil(HotplugMath.dockedOrigin(for: CGRect(x: 1920, y: 100, width: 1440, height: 900),
                                              among: [a]))
        // No neighbors → nothing to dock to.
        XCTAssertNil(HotplugMath.dockedOrigin(for: a, among: []))
    }

    func testDockedOriginSnapsAnOverlapFlush() {
        // Dropped overlapping the existing display → docks to the nearest free edge.
        let dropped = CGRect(x: 1800, y: 0, width: 1440, height: 900)
        let docked = HotplugMath.dockedOrigin(for: dropped, among: [a])
        XCTAssertEqual(docked, CGPoint(x: 1920, y: 0), "nearest candidate is flush right")
    }

    func testDockedOriginAvoidsOccupiedEdges() {
        // Right edge occupied; a newcomer overlapping the pair docks somewhere free.
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let dropped = CGRect(x: 1000, y: 100, width: 800, height: 600)
        let docked = HotplugMath.dockedOrigin(for: dropped, among: [a, right])
        XCTAssertNotNil(docked)
        let placed = CGRect(origin: docked!, size: dropped.size)
        XCTAssertFalse(placed.insetBy(dx: 1, dy: 1).intersects(a), "no overlap with a")
        XCTAssertFalse(placed.insetBy(dx: 1, dy: 1).intersects(right), "no overlap with right")
    }
}
