import AppKit

/// Borderless windows can't become key by default, which would block keyboard
/// input and buttons on the overlays. This subclass allows it.
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
