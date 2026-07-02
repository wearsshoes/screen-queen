import CoreGraphics

/// When does a resolution change deserve the auto-revert countdown? Only when it
/// touched *every* connected display at once — then there may be no live screen
/// left to fix things from, and the change must be able to un-do itself. (Any
/// partial change leaves a working arranger somewhere; Undo covers those.)
enum RevertPolicy {
    /// True when `changed` covers all of `all` (and there was anything to cover).
    /// A single-display setup qualifies by construction: its one display is `all`.
    static func coversEveryDisplay(changed: Set<CGDirectDisplayID>,
                                   all: Set<CGDirectDisplayID>) -> Bool {
        !all.isEmpty && all.subtracting(changed).isEmpty
    }
}
