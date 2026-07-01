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

    private let capture = ScreenCaptureManager()

    init() {
        state.changed = { [weak self] in self?.canvases.forEach { $0.refresh() } }
        state.capture = capture
        // A new frame from any display just repaints the tiles (coalesced by AppKit).
        capture.onFrame = { [weak self] in self?.canvases.forEach { $0.needsDisplay = true } }
        state.onToggleFeed = { [weak self] on in self?.setFeed(on) }
    }

    /// Turn the live per-display feed on or off (from the toggle button).
    private func setFeed(_ on: Bool) {
        state.feedEnabled = on
        if on { capture.start() } else { capture.stop() }
        canvases.forEach { $0.refresh() }
    }

    /// Show an arranger on every screen (rebuilding to match the current screen set),
    /// and refresh the shared plane from the OS.
    func show(displays: [DisplaySnapshot]) {
        state.update(with: displays)
        rebuild()
        canvases.forEach { $0.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        // Activating alone doesn't make a borderless overlay key, so on hotkey-open the
        // arranger takes no keyboard focus until clicked. Make the main display's window
        // key so shortcuts (arrows, ⌘Z, ⌘Delete, Return) work immediately.
        makeMainWindowKey()
        // Default the live feed on unless the machine is already busy (>50% CPU) — a
        // heavy box shouldn't get a surprise capture load. The user can toggle it with the
        // leftmost button. Our overlays exist now, so capture can exclude them.
        let busy = (ScreenCaptureManager.systemCPUUsage() ?? 0) > 0.5
        setFeed(!busy)
    }

    /// Make the arranger window on the main display key (falling back to any window).
    private func makeMainWindowKey() {
        let mainID = state.displays.first(where: { $0.isMain })?.id
        let window = mainID.flatMap { windows[$0] } ?? windows.values.first
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        capture.stop()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        canvases.removeAll()
    }

    /// Re-interpret the OS layout into the shared plane and repaint (external change).
    /// `force` re-reads the plane even when it already matches (e.g. after Reset, which
    /// must discard any equivalent-but-edited plane).
    func refresh(displays: [DisplaySnapshot], force: Bool = false) {
        guard isVisible else { return }
        state.update(with: displays, force: force)
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
        // Sit just below the system menu bar so the arranger covers the desktop and
        // app windows, but the menu bar — and our status-bar icon — stay visible and
        // clickable on top. (The calibration panel / alerts sit above the arranger via
        // the shielding level.)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        // The backdrop softens the desktop/apps showing through the transparent overlay
        // while the arranger is active. On macOS 26 use native Liquid Glass (clear
        // style); older systems fall back to a behind-window .hudWindow blur. The canvas
        // (with its own dim wash) sits on top.
        let fullFrame = CGRect(origin: .zero, size: frame.size)
        let canvas = ArrangementCanvas(state: state, frame: fullFrame)
        canvas.centerID = centerID
        canvas.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            // `NSGlassEffectView` draws a light rim at its edges (the Liquid Glass border).
            // On a full-screen overlay that reads as a white outline around the whole screen.
            // Oversize the glass past the window bounds on every side so its rim falls outside
            // the visible area (clipped), and keep the canvas at the true full frame on top so
            // its own layout/bounds stay correct.
            let bleed: CGFloat = 24
            let host = NSView(frame: fullFrame)
            host.autoresizingMask = [.width, .height]
            let glass = NSGlassEffectView(frame: fullFrame.insetBy(dx: -bleed, dy: -bleed))
            glass.style = .clear
            glass.cornerRadius = 0
            glass.autoresizingMask = [.width, .height]
            host.addSubview(glass)
            host.addSubview(canvas)            // canvas on top, at the true full frame
            window.contentView = host
        } else {
            let blur = NSVisualEffectView(frame: fullFrame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.addSubview(canvas)
            window.contentView = blur
        }
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
