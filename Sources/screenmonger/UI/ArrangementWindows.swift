import AppKit

/// One full-screen borderless arranger window per display, all sharing a single
/// `ArrangementState`. Each window's canvas centers on its own screen's tile; a
/// mutation on any of them broadcasts through the state so all repaint.
@MainActor
final class ArrangementWindows {

    let state = ArrangementState()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var canvases: [ArrangementCanvas] = []

    var isVisible: Bool { !windows.isEmpty }

    init() {
        state.changed = { [weak self] in self?.canvases.forEach { $0.refresh() } }
    }

    /// Show an arranger on every screen (rebuilding to match the current screen set),
    /// and refresh the shared plane from the OS.
    func show(displays: [DisplaySnapshot], colors: [CGDirectDisplayID: NSColor]) {
        state.update(with: displays, colors: colors)
        rebuild()
        canvases.forEach { $0.refresh() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        canvases.removeAll()
    }

    /// Re-interpret the OS layout into the shared plane and repaint (external change).
    /// `force` re-reads the plane even when it already matches (e.g. after Reset, which
    /// must discard any equivalent-but-edited plane).
    func refresh(displays: [DisplaySnapshot], colors: [CGDirectDisplayID: NSColor], force: Bool = false) {
        guard isVisible else { return }
        state.update(with: displays, colors: colors, force: force)
        rebuild()   // screens may have changed
        canvases.forEach { $0.refresh() }
    }

    private func rebuild() {
        let screens = screenMap()
        var live: Set<CGDirectDisplayID> = []

        for (id, screen) in screens {
            live.insert(id)
            // A borderless overlay doesn't reliably land when `setFrame`-d across a
            // reconfig (it can end up off-screen), so recreate any window whose screen
            // frame changed — the clean teardown+rebuild always lands correctly.
            if let existing = windows[id], existing.frame != screen.frame {
                existing.orderOut(nil)
                canvases.removeAll { $0.centerID == id }
                windows[id] = nil
            }
            let window = windows[id] ?? makeWindow(centerID: id, frame: screen.frame)
            windows[id] = window
            window.orderFrontRegardless()
        }
        for (id, window) in windows where !live.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
            canvases.removeAll { $0.centerID == id }
        }
    }

    private func makeWindow(centerID: CGDirectDisplayID, frame: NSRect) -> NSWindow {
        let window = KeyableBorderlessWindow(contentRect: frame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let canvas = ArrangementCanvas(state: state, frame: CGRect(origin: .zero, size: frame.size))
        canvas.centerID = centerID
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        canvases.append(canvas)
        return window
    }

    private func screenMap() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[key] as? NSNumber { result[n.uint32Value] = screen }
        }
        return result
    }
}
