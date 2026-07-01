import CoreGraphics
import XCTest
@testable import Silkscreen

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
