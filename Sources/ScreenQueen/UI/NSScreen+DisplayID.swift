import AppKit

extension NSScreen {
    /// The CGDirectDisplayID this screen renders.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen currently rendering display `id`, if it's up.
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}
