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

    /// Mouse-move monitors feeding the beacon / ghost cursor (see VirtualMouse.swift);
    /// installed while visible, empty otherwise.
    private var mouseMonitors: [Any] = []

    /// At this many screens the live feed is a production number: it defaults off, and
    /// switching it on arms the feed-guard countdown + watchdog.
    static let bigCastThreshold = 4
    /// Off-main insurance for the feed guard — see `armFeedGuardIfBigCast`.
    private var feedWatchdog: DispatchWorkItem?

    init() {
        state.changed = { [weak self] in self?.canvases.forEach { $0.refresh() } }
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
        installMouseMonitors()
        mouseDidMove()   // seed the beacon/ghost before the first move
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
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        canvases.removeAll()
    }

    // MARK: - Virtual mouse feed (see VirtualMouse.swift for the aids themselves)

    /// The control a press began on, frozen for the press's duration — the
    /// "outside of a drag action" gate: while a button is held the halo never
    /// retargets (a slider scrub keeps its twin lit and mirrors the fraction; a
    /// tile drag that began off-target shows no halo at all).
    private var ghostPressTarget: GhostTarget?

    /// Follow the real mouse while visible. A global monitor covers moves over other
    /// apps' screens; a local one covers our own overlays (which accept mouseMoved).
    private func installMouseMonitors() {
        guard VirtualMouse.planeMarkerEnabled || VirtualMouse.ghostCursorEnabled,
              mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouse(event)
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouse(event)
            return event
        }) { mouseMonitors.append(l) }
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: pressBegan()
        case .leftMouseUp: ghostPressTarget = nil
        default: break
        }
        mouseDidMove()
    }

    /// Freeze the pressed control (if any) for the drag's duration, and echo the
    /// press on every other canvas's halo — the click, made visible everywhere.
    private func pressBegan() {
        let ctx = cursorContext()
        guard isVisible, let host = ctx.host, let p = ctx.hostPoint else { ghostPressTarget = nil; return }
        ghostPressTarget = host.ghostTarget(at: p)
        guard ghostPressTarget != nil else { return }
        for canvas in canvases where canvas !== host { canvas.flashGhostHighlight() }
    }

    /// One global cursor sample: where the cursor is, which display holds it (even a
    /// canvas-less one — a mirrored slave shares her master's global bounds, and the
    /// beacon still wants her id), and the canvas + view point when we have one there.
    private func cursorContext() -> (cursor: CGPoint, displayID: CGDirectDisplayID?,
                                     host: Arranger?, hostPoint: CGPoint?) {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        // Prefer plane displays so the id resolves to a canvas when both match.
        let displayID = (state.planeDisplays.first { CGDisplayBounds($0.id).contains(cursor) }
            ?? state.displays.first { CGDisplayBounds($0.id).contains(cursor) })?.id
        guard let displayID, let host = canvases.first(where: { $0.centerID == displayID }),
              let window = windows[displayID] else { return (cursor, displayID, nil, nil) }
        let loc = NSEvent.mouseLocation   // Cocoa global (y-up); the canvas fills the window
        return (cursor, displayID, host,
                CGPoint(x: loc.x - window.frame.minX, y: loc.y - window.frame.minY))
    }

    /// Fan the cursor sample out to every canvas — each places its own beacon/ghost/
    /// halo and chrome presence through its own geometry. The target (control under
    /// the cursor) is computed ONCE here, host-side.
    private func mouseDidMove() {
        guard isVisible else { return }
        let ctx = cursorContext()
        let pressed = NSEvent.pressedMouseButtons != 0
        let target: GhostTarget?
        if pressed {
            target = ghostPressTarget         // frozen for the drag (nil ⇒ no halo)
        } else {
            ghostPressTarget = nil            // belt: ups can be missed across spaces
            if let host = ctx.host, let p = ctx.hostPoint { target = host.ghostTarget(at: p) }
            else { target = nil }
        }
        for canvas in canvases {
            canvas.updateMouseOverlays(cursor: ctx.cursor, hostID: ctx.displayID,
                                       host: ctx.host, hostPoint: ctx.hostPoint, target: target)
        }
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
        // mouseMoved events aren't generated for a window that doesn't ask; the local
        // mouse monitor (the beacon/ghost feed) needs them while the cursor is on us.
        window.acceptsMouseMovedEvents = true

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
