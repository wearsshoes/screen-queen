import CoreGraphics
import XCTest
@testable import ScreenQueen

/// Round-trip and seam-map invariants for `SchematicLayout`. The point↔physical
/// seam map must be a faithful inverse pair so a committed layout doesn't drift
/// (and the reference bars measure the true point overlap).
final class SchematicLayoutTests: XCTestCase {

    /// A minimal snapshot; only id/bounds/physicalSizeMM/isMain matter to the layout.
    private func snap(_ id: CGDirectDisplayID, _ bounds: CGRect, mm: CGSize,
                      main: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, name: "d\(id)", bounds: bounds,
            pixelSize: CGSize(width: bounds.width, height: bounds.height),
            physicalSizeMM: mm, physicalSizeIsCalibrated: false,
            isMain: main, isBuiltin: main, vendor: 0, model: 0, serial: 0,
            refreshHz: 60
        )
    }

    /// The reported real-world config: a 15″ built-in main, a 27″ Sceptre stacked
    /// above it, and a second 27″ Sceptre on the right spanning the seam. The right
    /// screen is physically *taller* than its built-in parent, which makes the seam
    /// map non-monotonic — the case that used to drift on the way back to points.
    private func threeDisplays() -> [DisplaySnapshot] {
        [snap(1, CGRect(x: 0, y: 0, width: 1710, height: 1107),
              mm: CGSize(width: 326.5714, height: 211.412), main: true),
         snap(2, CGRect(x: 1710, y: -549, width: 1920, height: 1080),
              mm: CGSize(width: 602.1, height: 338.7)),
         snap(3, CGRect(x: -210, y: -1080, width: 1920, height: 1080),
              mm: CGSize(width: 602.1, height: 338.7))]
    }

    /// `toPlane` then `toPoints` must reproduce the original point arrangement (up to
    /// the global translation that pins the main at the origin).
    func testRoundTripReproducesPointArrangement() {
        let displays = threeDisplays()
        let plane = SchematicLayout.toPlane(displays)
        let origins = SchematicLayout.toPoints(rects: plane, displays: displays)

        // Compare relative to the main so a whole-plane translation doesn't count.
        let main = displays.first { $0.isMain }!
        let dx = origins[main.id]!.x - main.bounds.minX
        let dy = origins[main.id]!.y - main.bounds.minY
        for d in displays {
            let o = origins[d.id]!
            XCTAssertEqual(o.x - dx, d.bounds.minX, accuracy: 1, "\(d.name) x drifted")
            XCTAssertEqual(o.y - dy, d.bounds.minY, accuracy: 1, "\(d.name) y drifted")
        }
    }

    /// The reference-bar crossing region is the *point* overlap, identical on both
    /// screens. For the right Sceptre's left edge, that's ~549 pts facing the top
    /// Sceptre and ~531 pts facing the built-in — nearly equal, per the arrangement.
    /// (The bug rendered these as 208 / 872.)
    func testSeamBarsMeasureTruePointOverlap() {
        let displays = threeDisplays()
        let plane = SchematicLayout.toPlane(displays)
        let bars = SchematicLayout.seamBars(displays, rects: plane)

        func windowPoints(_ a: CGDirectDisplayID, _ b: CGDirectDisplayID) -> CGFloat? {
            bars.first { ($0.aID == a && $0.bID == b) || ($0.aID == b && $0.bID == a) }?.windowPoints
        }
        XCTAssertEqual(windowPoints(2, 3)!, 549, accuracy: 2)   // right Sceptre ↔ top Sceptre
        XCTAssertEqual(windowPoints(1, 2)!, 531, accuracy: 2)   // right Sceptre ↔ built-in
    }

    /// `seamPoint` inverts `seamPhysical` segment-by-segment (not by re-sorting), so
    /// the pair round-trips even where the physical anchors are non-monotonic — for
    /// every physical value a screen actually occupies (outside the narrow fold where
    /// the map genuinely has two preimages).
    func testSeamMapRoundTripsOutsideFold() {
        // Right Sceptre (child) docked to the built-in (parent): non-monotonic anchors.
        let child = threeDisplays()[1]
        let parent = threeDisplays()[0]
        let cs = SchematicLayout.physSize(child)
        let pr = CGRect(origin: .zero, size: SchematicLayout.physSize(parent))
        let anchors = SchematicLayout.seamAnchors(child: child, cs,
                                                  parentPoint: parent.bounds, parentPhys: pr,
                                                  vertical: true)
        // The child's true point minY (-549) sits outside the fold, so it must round-trip.
        let pointMinY: CGFloat = -549
        let phys = SchematicLayout.seamPhysical(pointMinY, anchors)
        XCTAssertEqual(SchematicLayout.seamPoint(phys, anchors), pointMinY, accuracy: 0.5)
    }

    /// A display dropped into an L-junction — abutting two *perpendicular* neighbors at
    /// once — must seat into the corner against both, so both seams survive the point
    /// reconstruction (previously it docked to a single neighbor and dropped the other edge).
    ///
    /// Layout (point space, y-down): a 1000×1000 main at the origin; display 2 the same size
    /// directly to its right (shared vertical seam); display 3 the same size directly below
    /// the main (shared horizontal seam) *and* below display 2 — so 3's top edge meets both
    /// 1 and 2, an inner corner at (1000, 1000).
    func testLJunctionDocksToBothNeighbors() {
        let mm = CGSize(width: 500, height: 500)   // square, so point and physical align cleanly
        let displays = [
            snap(1, CGRect(x: 0, y: 0, width: 1000, height: 1000), mm: mm, main: true),
            snap(2, CGRect(x: 1000, y: 0, width: 1000, height: 1000), mm: mm),
            snap(3, CGRect(x: 500, y: 1000, width: 1000, height: 1000), mm: mm),   // straddles the 1|2 corner
        ]
        let plane = SchematicLayout.toPlane(displays)
        let bars = SchematicLayout.seamBars(displays, rects: plane)

        func hasSeam(_ a: CGDirectDisplayID, _ b: CGDirectDisplayID) -> Bool {
            bars.contains { ($0.aID == a && $0.bID == b) || ($0.aID == b && $0.bID == a) }
        }
        // 3 must share a seam with *both* the main and display 2 — it sits in the corner.
        XCTAssertTrue(hasSeam(1, 3), "L-junction display should keep its seam with the main")
        XCTAssertTrue(hasSeam(2, 3), "L-junction display should keep its seam with the perpendicular neighbor")
        XCTAssertTrue(hasSeam(1, 2), "the top pair's own seam should also hold")
    }

    /// A wide top display straddling two bottom displays should have its two bottom seams
    /// meet exactly where the bottom pair meet — *in physical (plane) space*, which is what's
    /// rendered. (In point space they meet at the junction tautologically, since the seam
    /// regions are defined by point overlap; the interesting question is the physical layout.)
    ///
    /// Layout from the reported real config: the 15″ built-in main (Electra) bottom-left at the
    /// origin, a 27″ (Scarlet) directly to its right sharing a vertical seam, and a 27″ (Delta)
    /// on top straddling both. On Delta's physical bottom edge, the seam-with-Electra region and
    /// the seam-with-Scarlet region must abut at the physical Electra|Scarlet junction x — not
    /// be anchored to the main's left edge.
    func testTopDisplaySeamsMeetAtBottomJunctionPhysically() {
        let electra = snap(1, CGRect(x: 0, y: 0, width: 1710, height: 1107),
                           mm: CGSize(width: 326.5714, height: 211.412), main: true)
        let scarlet = snap(2, CGRect(x: 1710, y: 0, width: 2560, height: 1440),
                           mm: CGSize(width: 596.7, height: 335.6))
        let delta = snap(3, CGRect(x: 600, y: -1440, width: 2560, height: 1440),
                         mm: CGSize(width: 596.7, height: 335.6))
        let displays = [electra, scarlet, delta]
        let plane = SchematicLayout.toPlane(displays)
        let bars = SchematicLayout.seamBars(displays, rects: plane)

        // The physical junction: where Electra and Scarlet meet on the plane.
        let junctionPhysX = plane[1]!.maxX
        XCTAssertEqual(plane[2]!.minX, junctionPhysX, accuracy: 0.1, "Electra|Scarlet must physically abut")

        // Delta's two bottom seam regions, in *physical* x on Delta: center (`physAlong`) ±
        // half the physical length (`physLenInches`), taking whichever side of the bar is Delta.
        func physRegion(_ other: CGDirectDisplayID) -> (lo: CGFloat, hi: CGFloat)? {
            guard let bar = bars.first(where: {
                ($0.aID == 3 && $0.bID == other) || ($0.aID == other && $0.bID == 3)
            }) else { return nil }
            let deltaIsA = bar.aID == 3
            let center = deltaIsA ? bar.physAlongA : bar.physAlongB
            let half = (deltaIsA ? bar.physLenInchesA : bar.physLenInchesB) / 2
            return (center - half, center + half)
        }
        guard let withElectra = physRegion(1), let withScarlet = physRegion(2) else {
            return XCTFail("Delta should share a bottom seam with both Electra and Scarlet")
        }
        // Both inner edges land on the physical junction — the pink/yellow seams meet at the
        // purple line.
        XCTAssertEqual(withElectra.hi, junctionPhysX, accuracy: 0.5, "top↔Electra region should physically end at the junction")
        XCTAssertEqual(withScarlet.lo, junctionPhysX, accuracy: 0.5, "top↔Scarlet region should physically start at the junction")
    }

    /// Same straddling layout, but through the *drag* path: lock the settled solve, then move
    /// the top display a touch and re-solve with `lockedSolve` (the frozen-neighbor path used
    /// while dragging). The two bottom seams must still meet at the Electra|Scarlet junction —
    /// the mover's x should be pinned to the junction below it, not to the main's left edge.
    func testDragLockedTopDisplaySeamsMeetAtBottomJunction() {
        let electra = snap(1, CGRect(x: 0, y: 0, width: 1710, height: 1107),
                           mm: CGSize(width: 326.5714, height: 211.412), main: true)
        let scarlet = snap(2, CGRect(x: 1710, y: 0, width: 2560, height: 1440),
                           mm: CGSize(width: 596.7, height: 335.6))
        let delta = snap(3, CGRect(x: 600, y: -1440, width: 2560, height: 1440),
                         mm: CGSize(width: 596.7, height: 335.6))
        let displays = [electra, scarlet, delta]
        var plane = SchematicLayout.toPlane(displays)
        let locked = SchematicLayout.toPoints(rects: plane, displays: displays)

        // Nudge the top display (id 3) on the physical plane, as a drag would.
        plane[3] = plane[3]!.offsetBy(dx: 5, dy: 0)
        let origins = SchematicLayout.lockedSolve(rects: plane, displays: displays, locked: locked, dragged: 3)

        let junctionPhysX = plane[1]!.maxX
        let bars = SchematicLayout.seamBars(displays, rects: plane, origins: origins)
        func physRegion(_ other: CGDirectDisplayID) -> (lo: CGFloat, hi: CGFloat)? {
            guard let bar = bars.first(where: {
                ($0.aID == 3 && $0.bID == other) || ($0.aID == other && $0.bID == 3)
            }) else { return nil }
            let deltaIsA = bar.aID == 3
            let center = deltaIsA ? bar.physAlongA : bar.physAlongB
            let half = (deltaIsA ? bar.physLenInchesA : bar.physLenInchesB) / 2
            return (center - half, center + half)
        }
        guard let withElectra = physRegion(1), let withScarlet = physRegion(2) else {
            return XCTFail("Delta should share a bottom seam with both Electra and Scarlet")
        }
        XCTAssertEqual(withElectra.hi, junctionPhysX, accuracy: 0.5, "top↔Electra region should physically end at the junction (drag)")
        XCTAssertEqual(withScarlet.lo, junctionPhysX, accuracy: 0.5, "top↔Scarlet region should physically start at the junction (drag)")
    }

    /// Even in the *fold* region — where the right Sceptre's dock-seam to the built-in
    /// has multiple point preimages — the round-trip is unique, because the seam it
    /// also shares with the top Sceptre inverts unambiguously and pins the answer.
    func testRoundTripDisambiguatesInFoldViaSeamSet() {
        // Slide the right Sceptre up so its dock-seam (to the built-in) lands in the
        // fold: point minY = -202.5 → physical minY ≈ -2.5, which the built-in seam
        // alone maps to three preimages.
        var displays = threeDisplays()
        let foldMinY: CGFloat = -202.5
        displays[1] = displays[1].with(bounds: CGRect(x: 1710, y: foldMinY, width: 1920, height: 1080))
        let plane = SchematicLayout.toPlane(displays)
        let origins = SchematicLayout.toPoints(rects: plane, displays: displays)

        let main = displays.first { $0.isMain }!
        let dy = origins[main.id]!.y - main.bounds.minY
        XCTAssertEqual(origins[2]!.y - dy, foldMinY, accuracy: 2,
                       "fold-region right Sceptre should still round-trip via the top-Sceptre seam")
    }
}
