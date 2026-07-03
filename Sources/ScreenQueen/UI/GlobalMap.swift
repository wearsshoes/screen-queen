import AppKit

/// The global map: the real desk, in the OS's two global coordinate systems.
/// Quartz/CG global space is y-down with the origin at the primary display's
/// top-left (`CGDisplayBounds`, `CGEvent` cursor samples); Cocoa global space is
/// y-up with the origin at its bottom-left (`NSScreen.frame`, `NSWindow` frames).
/// The primary display anchors both at (0,0), so the flip is about its height.
///
/// Everything that converts between the two, resolves a display to its screen, or
/// measures the desk as a whole lives here — one home instead of a hand-rolled
/// flip per feature.
enum GlobalMap {

    /// CG global point (cursor samples) → Cocoa global point (window space).
    static func cocoaPoint(fromCG p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// CG global rect → Cocoa global rect (ready for an NSWindow frame).
    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static var primaryHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// The live displayID → NSScreen table.
    static func screenMap() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { result[id] = screen }
        }
        return result
    }

    /// The display hosting a CG-global cursor point. Plane displays win over
    /// mirrored slaves when bounds overlap (a slave shares its master's pixels
    /// but has its own `CGDisplayBounds`).
    static func hostDisplayID(cursor: CGPoint, planeFirst plane: [DisplaySnapshot],
                              all: [DisplaySnapshot]) -> CGDirectDisplayID? {
        (plane.first { CGDisplayBounds($0.id).contains(cursor) }
            ?? all.first { CGDisplayBounds($0.id).contains(cursor) })?.id
    }

    /// The desk-wide chrome facts: the largest Dock / menu-bar claim anywhere and
    /// the smallest screen extents. Chrome placed within these is in-bounds on
    /// every screen, identically.
    static func uniformInsets() -> (dock: CGFloat, menuBar: CGFloat, minExtent: CGSize) {
        var dock: CGFloat = 0, menu: CGFloat = 0
        var minW = CGFloat(100_000), minH = CGFloat(100_000)
        for s in NSScreen.screens {
            dock = max(dock, s.visibleFrame.minY - s.frame.minY)
            menu = max(menu, s.frame.maxY - s.visibleFrame.maxY)
            minW = min(minW, s.frame.width)
            minH = min(minH, s.frame.height)
        }
        return (dock, menu, CGSize(width: minW, height: minH))
    }
}

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
