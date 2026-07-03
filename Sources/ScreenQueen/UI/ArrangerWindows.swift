import AppKit

/// One full-screen borderless arranger window per display, all sharing a single
/// `ArrangerState`. Each window's canvas centers on its own screen's tile; a
/// mutation on any of them broadcasts through the state so all repaint.
@MainActor
final class ArrangerWindows {

    let state = ArrangerState()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var canvases: [Arranger] = []

    var isVisible: Bool { !windows.isEmpty }

    private let capture = ScreenCaptureManager()

    /// At this many screens the live feed is a production number: it defaults off, and
    /// switching it on arms the feed-guard countdown + watchdog.
    static let bigCastThreshold = 4
    /// Off-main insurance for the feed guard — see `armFeedGuardIfBigCast`.
    private var feedWatchdog: DispatchWorkItem?

    init() {
        state.changed = { [weak self] in
            self?.canvases.forEach { $0.refresh() }
            self?.refreshGhostChrome()   // a layout/panel change moves the projections
        }
        state.capture = capture
        // A new frame from any display just repaints the tiles (coalesced by AppKit).
        capture.onFrame = { [weak self] in self?.canvases.forEach { $0.needsDisplay = true } }
        state.onToggleFeed = { [weak self] on in self?.setFeed(on) }
        // However a feed-guard countdown ends (keep, cut-now, expiry), the watchdog
        // stands down with it.
        state.onCountdownResolved = { [weak self] kind in
            if kind == .feedGuard { self?.cancelFeedWatchdog() }
        }
    }

    /// Reproject the ghost chrome (see VirtualMouse.swift): every canvas draws pink
    /// images of every *other* canvas's controls, through the shared affine transform.
    /// Deferred one runloop turn so button-bar autolayout has settled into real frames.
    private func refreshGhostChrome() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for canvas in self.canvases {
                canvas.renderGhostChrome(from: self.canvases.filter { $0 !== canvas })
            }
        }
    }

    /// Turn the live per-display feed on or off (from the toggle button).
    private func setFeed(_ on: Bool) {
        state.feedEnabled = on
        if on {
            capture.start()
            armFeedGuardIfBigCast()
        } else {
            capture.stop()
            // No-op unless a guard was running (its own expiry lands here too).
            state.resolveCountdown(.feedGuard, keep: true)
        }
        canvases.forEach { $0.refresh() }
    }

    /// Going live on `bigCastThreshold`+ screens arms an auto-off: the feed cuts
    /// itself after the countdown unless the user says keep (the banner, Arranger+
    /// Banner.swift). Belt: if the capture load wedges the main thread, that Timer
    /// never fires — so a detached watchdog can still stop the streams directly
    /// (`SCStream.stopCapture` is safe off-main) a grace period later, then settle
    /// the UI state once the main thread breathes again.
    private func armFeedGuardIfBigCast() {
        guard NSScreen.screens.count >= Self.bigCastThreshold else { return }
        let seconds = 12
        state.armCountdown(.feedGuard, seconds: seconds) { [weak self] in self?.setFeed(false) }

        feedWatchdog?.cancel()
        let capture = self.capture
        let item = DispatchWorkItem { [weak self] in
            for stream in capture.watchdogStreams { stream.stopCapture { _ in } }
            DispatchQueue.main.async { self?.setFeed(false) }
        }
        feedWatchdog = item
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + .seconds(seconds + 5), execute: item)
    }

    private func cancelFeedWatchdog() {
        feedWatchdog?.cancel()
        feedWatchdog = nil
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
        // heavy box shouldn't get a surprise capture load — or the cast is big (4+
        // screens: that much cross-streaming can bog the whole show down). The user
        // can toggle it with the leftmost button; on a big cast that arms the feed
        // guard. Our overlays exist now, so capture can exclude them.
        let busy = (ScreenCaptureManager.systemCPUUsage() ?? 0) > 0.5
        let bigCast = NSScreen.screens.count >= Self.bigCastThreshold
        setFeed(!busy && !bigCast)
        refreshGhostChrome()   // project each screen's controls onto the others
    }

    /// Make the arranger window on the main display key (falling back to any window).
    private func makeMainWindowKey() {
        let mainID = state.displays.first(where: { $0.isMain })?.id
        let window = mainID.flatMap { windows[$0] } ?? windows.values.first
        window?.makeKeyAndOrderFront(nil)
    }

    /// Key the canvas on `screen` (focus-follows-cursor, driven by `FocusPolicy`).
    /// Mirrors calibration's don't-steal semantics: no-op when not visible or when
    /// any of our windows on that screen is already key.
    func focusWindow(on screen: NSScreen) {
        guard isVisible else { return }
        let window = windows.values.first { $0.screen?.frame == screen.frame }
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
    }

    func hide() {
        capture.stop()
        cancelFeedWatchdog()
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
        refreshGhostChrome()
    }

    /// Refresh the unified chrome metrics (see `ArrangerState`): the largest Dock and
    /// menu-bar claims anywhere, and the smallest screen extents, so every canvas
    /// places its chrome at identical, everywhere-in-bounds anchor offsets.
    private func updateChromeMetrics() {
        var dock: CGFloat = 0, menu: CGFloat = 0
        var minW = CGFloat(100_000), minH = CGFloat(100_000)
        for s in NSScreen.screens {
            dock = max(dock, s.visibleFrame.minY - s.frame.minY)
            menu = max(menu, s.frame.maxY - s.visibleFrame.maxY)
            minW = min(minW, s.frame.width)
            minH = min(minH, s.frame.height)
        }
        state.uniformDockInset = dock
        state.uniformMenuBarInset = menu
        state.minScreenExtent = CGSize(width: minW, height: minH)
    }

    private func rebuild() {
        updateChromeMetrics()
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
        let canvas = Arranger(state: state, frame: fullFrame)
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
