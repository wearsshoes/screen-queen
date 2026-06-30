import AppKit

/// Manages the transparent, click-through overlay window on each display that
/// renders the reference boxes. Windows are created lazily and torn down when
/// the overlays are hidden or a display disconnects.
@MainActor
final class OverlayController {

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private(set) var isVisible = false

    func toggle(with displays: [DisplaySnapshot]) {
        if isVisible { hide() } else { show(with: displays) }
    }

    func show(with displays: [DisplaySnapshot]) {
        isVisible = true
        update(with: displays)
    }

    func hide() {
        isVisible = false
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    /// Rebuild overlay content from a fresh snapshot. No-op while hidden.
    func update(with displays: [DisplaySnapshot]) {
        guard isVisible else { return }

        let junctions = DisplayGraph.junctions(displays)
        let colors = DisplayGraph.colors(displays)
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let screens = screenMap()

        // Anchor the reference element to 10 cm on the reference (main) screen,
        // then draw that same point-length on every screen so the per-screen
        // physical lengths reveal how a dragged window changes size.
        let referenceCM = 10.0
        let refPPT = displays.first(where: { $0.isMain })?.pointsPerInch
            ?? displays.compactMap { $0.pointsPerInch }.first ?? 100
        let referenceLengthPoints = CGFloat(referenceCM / 2.54 * refPPT)

        var live: Set<CGDirectDisplayID> = []
        for d in displays {
            guard let screen = screens[d.id] else { continue }
            live.insert(d.id)

            let window = windows[d.id] ?? makeWindow()
            windows[d.id] = window
            window.setFrame(screen.frame, display: false)

            if let view = window.contentView as? OverlayView {
                view.frame = CGRect(origin: .zero, size: screen.frame.size)
                view.configure(me: d, byID: byID, junctions: junctions, colors: colors,
                               referenceLengthPoints: referenceLengthPoints)
            }
            window.orderFrontRegardless()
        }

        for (id, window) in windows where !live.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let view = OverlayView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return window
    }

    private func screenMap() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber {
                result[number.uint32Value] = screen
            }
        }
        return result
    }
}
