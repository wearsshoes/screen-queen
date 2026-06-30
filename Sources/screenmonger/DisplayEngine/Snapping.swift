import CoreGraphics

enum MoveDirection {
    case up, down, left, right
    var isVertical: Bool { self == .up || self == .down }
}

enum VAnchor: Equatable { case top, center, bottom }
enum HAnchor: Equatable { case left, center, right }

/// A vertical alignment position for the selected display: a target `minY` plus
/// which anchors line up (for highlighting the alignment markers). Values are
/// computed in physical space by `SchematicLayout.verticalSnaps`.
struct VSnap {
    let value: CGFloat
    let selfAnchor: VAnchor
    let otherAnchor: VAnchor
    let otherID: CGDirectDisplayID
}

struct HSnap {
    let value: CGFloat
    let selfAnchor: HAnchor
    let otherAnchor: HAnchor
    let otherID: CGDirectDisplayID
}
