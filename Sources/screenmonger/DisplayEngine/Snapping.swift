import CoreGraphics

/// Shared alignment vocabulary. Snap positions themselves are computed in physical
/// space by `SchematicLayout` (`physSnapsH/V`); this file just holds the small
/// value types the UI and engine pass around.

enum MoveDirection {
    case up, down, left, right
    var isVertical: Bool { self == .up || self == .down }
}

enum VAnchor: Equatable { case top, center, bottom }
enum HAnchor: Equatable { case left, center, right }
