import CoreGraphics

/// Shared alignment vocabulary. Where along a seam two displays line up is one of
/// these anchors; `SchematicLayout.physSnapsH/V` turn them into physical positions.
enum VAnchor: Equatable { case top, center, bottom }
enum HAnchor: Equatable { case left, center, right }

/// A keyboard/arrow move direction.
enum MoveDirection {
    case up, down, left, right
    var isVertical: Bool { self == .up || self == .down }
}
