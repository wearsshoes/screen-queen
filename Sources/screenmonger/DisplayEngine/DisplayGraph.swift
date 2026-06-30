import AppKit
import CoreGraphics

/// A shared edge segment between two adjacent displays.
///
/// `aID` is the left (vertical seam) or top (horizontal seam) display; `bID` the
/// right/bottom one. `line` is the global coordinate of the seam itself; `midpoint`
/// is the global coordinate of the *overlap* midpoint along the seam — which lands
/// at different relative positions on each screen when their sizes/alignment differ.
struct Junction {
    let aID: CGDirectDisplayID
    let bID: CGDirectDisplayID
    let isVertical: Bool   // true: seam is a vertical line (screens side by side)
    let line: CGFloat
    let midpoint: CGFloat
}

/// Adjacency analysis over the display arrangement: junction detection plus a
/// greedy graph-coloring so neighboring screens always get distinct colors.
enum DisplayGraph {

    static let palette: [NSColor] = [
        .systemPink, .systemGreen, .systemBlue, .systemOrange,
        .systemPurple, .systemTeal, .systemYellow, .systemRed
    ]

    static func junctions(_ displays: [DisplaySnapshot]) -> [Junction] {
        let tol: CGFloat = 1.5
        var result: [Junction] = []
        guard displays.count > 1 else { return result }

        for i in 0..<displays.count {
            for j in (i + 1)..<displays.count {
                let A = displays[i].bounds, B = displays[j].bounds
                let aID = displays[i].id, bID = displays[j].id

                // Vertical seam: one display's right edge meets the other's left.
                if abs(A.maxX - B.minX) <= tol {
                    let top = max(A.minY, B.minY), bot = min(A.maxY, B.maxY)
                    if bot - top > tol {
                        result.append(Junction(aID: aID, bID: bID, isVertical: true,
                                               line: A.maxX, midpoint: (top + bot) / 2))
                    }
                } else if abs(B.maxX - A.minX) <= tol {
                    let top = max(A.minY, B.minY), bot = min(A.maxY, B.maxY)
                    if bot - top > tol {
                        result.append(Junction(aID: bID, bID: aID, isVertical: true,
                                               line: B.maxX, midpoint: (top + bot) / 2))
                    }
                }

                // Horizontal seam: one display's bottom edge meets the other's top.
                // (CG global space is y-down, so maxY is the lower edge.)
                if abs(A.maxY - B.minY) <= tol {
                    let l = max(A.minX, B.minX), r = min(A.maxX, B.maxX)
                    if r - l > tol {
                        result.append(Junction(aID: aID, bID: bID, isVertical: false,
                                               line: A.maxY, midpoint: (l + r) / 2))
                    }
                } else if abs(B.maxY - A.minY) <= tol {
                    let l = max(A.minX, B.minX), r = min(A.maxX, B.maxX)
                    if r - l > tol {
                        result.append(Junction(aID: bID, bID: aID, isVertical: false,
                                               line: B.maxY, midpoint: (l + r) / 2))
                    }
                }
            }
        }
        return result
    }

    /// Assign each display a distinct palette color, keyed to a stable id order.
    /// Distinct-by-index (rather than minimal graph coloring) keeps colors stable
    /// while dragging and guarantees neighbors always differ for any realistic
    /// monitor count.
    static func colors(_ displays: [DisplaySnapshot]) -> [CGDirectDisplayID: NSColor] {
        var assigned: [CGDirectDisplayID: NSColor] = [:]
        for (i, d) in displays.sorted(by: { $0.id < $1.id }).enumerated() {
            assigned[d.id] = palette[i % palette.count]
        }
        return assigned
    }
}
