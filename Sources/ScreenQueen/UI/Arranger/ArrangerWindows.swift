import AppKit

/// One full-screen borderless arranger window per display, all sharing a single
/// `ArrangerState`. Each window's canvas centers on its own screen's tile; a mutation
/// on any of them broadcasts through the state so all repaint.
@MainActor
final class ArrangerWindows {

    let state = ArrangerState()
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var canvases: [Arranger] = []

    var isVisible: Bool { !windows.isEmpty }

    private let capture = ScreenCaptureManager()

    /// The shared event plumbing (set by the AppDelegate): mouse monitors + the
    /// slider-drag timer live there; this class consumes cursor samples.
    weak var events: EventPlumbing? {
        didSet { events?.onMouseSample = { [weak self] in self?.mouseDidMove() } }
    }
    /// The display the cursor is on. The chrome is re-rendered only when this changes;
    /// the ghost mouse moves every event.
    private var activeDisplayID: CGDirectDisplayID?

    /// At this many screens the live feed defaults off, and switching it on arms the
    /// feed-guard countdown + watchdog.
    static let bigCastThreshold = 4
    /// Off-main insurance for the feed guard — see `armFeedGuardIfBigCast`.
    private var feedWatchdog: DispatchWorkItem?

    init() {
        state.changed = { [weak self] in
            self?.canvases.forEach { $0.refresh() }
            self?.rerenderChrome()
        }
        state.onSliderDragChanged = { [weak self] dragging in self?.events?.setSliderDragging(dragging) }
        state.capture = capture
        capture.onFrame = { [weak self] in self?.canvases.forEach { $0.repaintSchematic() } }
        state.onToggleFeed = { [weak self] on in self?.setFeed(on) }
        state.onCountdownResolved = { [weak self] kind in
            if kind == .feedGuard { self?.cancelFeedWatchdog() }
        }
    }

    /// Re-render every canvas's chrome, deferred a runloop turn so button-bar autolayout
    /// has settled into real frames.
    private func rerenderChrome() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = self.activeDisplayID.flatMap { id in self.canvases.first { $0.centerID == id } }
            for canvas in self.canvases {
                canvas.renderChrome(active: canvas === active ? nil : active)
            }
        }
    }

    /// Turn the live per-display feed on or off.
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

    /// Going live on `bigCastThreshold`+ screens arms an auto-off unless the user says
    /// keep. Belt: if the capture load wedges the main thread that Timer never fires, so
    /// a detached watchdog stops the streams directly (`SCStream.stopCapture` is safe
    /// off-main) a grace period later.
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

    /// Show an arranger on every screen and refresh the shared plane from the OS.
    func show(displays: [DisplaySnapshot]) {
        state.update(with: displays)
        rebuild()
        canvases.forEach { $0.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        // Activating alone doesn't make a borderless overlay key; make the main
        // display's window key so shortcuts work immediately on hotkey-open.
        makeMainWindowKey()
        // Default the feed on unless the machine is already busy or the cast is big.
        let busy = (SystemLoad.systemCPUUsage() ?? 0) > 0.5
        let bigCast = NSScreen.screens.count >= Self.bigCastThreshold
        setFeed(!busy && !bigCast)
        if VirtualMouse.ghostMouseEnabled { events?.startMouseMonitors() }
        activeDisplayID = nil
        mouseDidMove()   // seed the active screen + render the ghost
        if state.feedEnabled { scheduleFeedLoadCheck() }
    }

    /// One follow-up CPU check ~½s after going live (the reading at open predates the
    /// streams). Sampled off-main (the sample blocks ~120ms). Deliberately a *single*
    /// check — no continuous repolling.
    private func scheduleFeedLoadCheck() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let pegged = (SystemLoad.systemCPUUsage() ?? 0) > 0.85
            guard pegged else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, self.state.feedEnabled else { return }
                self.setFeed(false)
            }
        }
    }

    /// Make the arranger window on the main display key (falling back to any window).
    private func makeMainWindowKey() {
        let mainID = state.displays.first(where: { $0.isMain })?.id
        let window = mainID.flatMap { windows[$0] } ?? windows.values.first
        window?.makeKeyAndOrderFront(nil)
    }

    /// Key the canvas on `screen` (focus-follows-cursor). No-op when not visible or a
    /// window on that screen is already key (don't-steal semantics).
    func focusWindow(on screen: NSScreen) {
        guard isVisible else { return }
        let window = windows.values.first { $0.screen?.frame == screen.frame }
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
    }

    func hide() {
        capture.stop()
        cancelFeedWatchdog()
        events?.stopMouseMonitors()
        activeDisplayID = nil
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        canvases.removeAll()
    }

    // MARK: - Ghost mouse feed (see VirtualMouse.swift)

    /// Quartz/CG global point (y-down, top-left of primary) → Cocoa global (y-up),
    /// flipped about the primary display's height.
    private func cocoaGlobal(fromCG p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? p.y
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// One cursor sample: reproject the chrome only when the active screen changed;
    /// always move the ghost mouse / beacon / tooltip.
    private func mouseDidMove() {
        guard isVisible else { return }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let activeID = (state.planeDisplays.first { CGDisplayBounds($0.id).contains(cursor) }
            ?? state.displays.first { CGDisplayBounds($0.id).contains(cursor) })?.id
        let active = activeID.flatMap { id in canvases.first { $0.centerID == id } }
        // The cursor in the active canvas's view coords, derived from the *same* CGEvent
        // sample — not `NSEvent.mouseLocation`, which a slider's modal tracking loop
        // clamps to the track (making the ghost cursor jump).
        var cursorActivePoint: CGPoint?
        if let activeID, let window = windows[activeID] {
            let up = cocoaGlobal(fromCG: cursor)
            cursorActivePoint = CGPoint(x: up.x - window.frame.minX, y: up.y - window.frame.minY)
        }
        if activeID != activeDisplayID {
            activeDisplayID = activeID
            // The selected tile follows the cursor's screen (crossing screens overrides a
            // manual pick; a click still selects within a screen).
            if let activeID, state.plane[activeID] != nil, state.selectedID != activeID {
                state.selectedID = activeID
                state.activeV = nil; state.activeH = nil   // drop stale alignment anchors
                state.notify()
            }
            for canvas in canvases { canvas.renderChrome(active: canvas === active ? nil : active) }
        }
        // The hovered control's tooltip trails the (ghost) cursor on every canvas.
        let tip = active.flatMap { a in cursorActivePoint.flatMap { a.hoveredTooltip(at: $0) } }
        for canvas in canvases {
            canvas.updateGhostArrow(cursorActivePoint: cursorActivePoint, isActive: canvas === active)
            canvas.updatePlaneMarker(cursor: cursor, hostID: activeID)
            canvas.updateTooltip(text: tip, cursorActivePoint: cursorActivePoint)
        }
    }

    /// Re-interpret the OS layout into the shared plane and repaint (external change).
    /// `force` re-reads the plane even when it already matches (e.g. after Reset).
    func refresh(displays: [DisplaySnapshot], force: Bool = false) {
        guard isVisible else { return }
        state.update(with: displays, force: force)
        rebuild()   // screens may have changed
        canvases.forEach { $0.refresh() }
        rerenderChrome()
    }

    /// Refresh the unified chrome metrics (see `ArrangerState`).
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
            // reconfig — recreate any window whose screen frame changed.
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
        // Just below the system menu bar, so the menu bar and our status icon stay
        // clickable on top. (Calibration/alerts sit above via the shielding level.)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        // Backdrop: native Liquid Glass on macOS 26, behind-window blur below. The
        // canvas (with its own dim wash) sits on top.
        let fullFrame = CGRect(origin: .zero, size: frame.size)
        let canvas = Arranger(state: state, frame: fullFrame)
        canvas.centerID = centerID
        canvas.autoresizingMask = [.width, .height]
        canvas.onLayout = { [weak self] in self?.rerenderChrome() }

        if #available(macOS 26.0, *) {
            // `NSGlassEffectView` draws a light rim at its edges, which reads as a white
            // outline around the whole screen — oversize the glass past the window bounds
            // so the rim falls outside the visible area.
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
        for screen in NSScreen.screens {
            if let id = screen.displayID { result[id] = screen }
        }
        return result
    }
}
