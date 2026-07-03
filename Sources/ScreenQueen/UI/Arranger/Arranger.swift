import AppKit

/// One full-screen borderless arranger window per display, all sharing a single
/// `ArrangerState`. Each window's stage centers on its own screen's tile; a mutation
/// on any of them broadcasts through the state so all repaint.
@MainActor
final class Arranger {

    let state = ArrangerState()
    /// The window fleet — one overlay per screen, just below the system menu bar so
    /// the menu bar and our status icon stay clickable on top. (Calibration/alerts
    /// sit above via the shielding level.)
    private let ensemble = Ensemble(
        level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1),
        collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
    private var windows: [CGDirectDisplayID: NSWindow] { ensemble.windows }
    private var stages: [Stage] = []

    var isVisible: Bool { ensemble.isVisible }

    private let capture = ScreenCaptureManager()

    /// The shared event plumbing (set by the AppDelegate): mouse monitors + the
    /// slider-drag timer live there; this class consumes cursor samples.
    weak var events: EventPlumbing? {
        didSet {
            events?.onMouseSample = { [weak self] in self?.mouseDidMove() }
            // Keyboard rides monitors, not the responder chain: route to the key
            // window's stage — the same window AppKit would have dispatched to.
            // NSEvent is decoded HERE; the handlers speak KeyInput/ModifierKeys.
            events?.onArrangerKeyDown = { [weak self] e in
                self?.keyStage()?.handleKeyDown(Self.keyInput(e)) ?? false
            }
            events?.onArrangerKeyUp = { [weak self] e in
                self?.keyStage()?.handleKeyUp(Self.keyInput(e)) ?? false
            }
            events?.onArrangerFlagsChanged = { [weak self] e in
                let f = e.modifierFlags
                self?.keyStage()?.handleFlagsChanged(
                    ModifierKeys(cmd: f.contains(.command), shift: f.contains(.shift)))
            }
        }
    }

    /// The stage that owns keyboard input right now: the key window's, and only when
    /// the key window is one of ours — calibration panels and the Backstage Pass keep
    /// their own keys even while the arranger is up behind them.
    private func keyStage() -> Stage? {
        guard isVisible, let key = NSApp.keyWindow,
              windows.values.contains(key) else { return nil }
        return stages.first { $0.window === key }
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
        ensemble.dress = { [weak self] id, window in self?.dress(window, centerID: id) }
        ensemble.retire = { [weak self] id in self?.stages.removeAll { $0.centerID == id } }
        state.changed = { [weak self] in
            self?.stages.forEach { $0.refresh() }
            self?.rerenderChrome()
        }
        state.onSliderDragChanged = { [weak self] dragging in self?.events?.setSliderDragging(dragging) }
        state.capture = capture
        capture.onFrame = { [weak self] in self?.stages.forEach { $0.repaintSchematic() } }
        state.onToggleFeed = { [weak self] on in self?.setFeed(on) }
        state.onCountdownResolved = { [weak self] kind in
            if kind == .feedGuard { self?.cancelFeedWatchdog() }
        }
    }

    /// Re-render every stage's chrome, deferred a runloop turn so button-bar autolayout
    /// has settled into real frames.
    private func rerenderChrome() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = self.activeDisplayID.flatMap { id in self.stages.first { $0.centerID == id } }
            for stage in self.stages {
                stage.renderChrome(active: stage === active ? nil : active)
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
        // Through the broadcast, not a bare refresh — the feed button lives on the
        // bar, and the bar renders on the chrome pass that follows a notify.
        state.notify()
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
        stages.forEach { $0.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        // Activating alone doesn't make a borderless overlay key; make the main
        // display's window key so shortcuts work immediately on hotkey-open.
        makeMainWindowKey()
        // Default the feed on unless the machine is already busy or the cast is big.
        let busy = (SystemLoad.systemCPUUsage() ?? 0) > 0.5
        let bigCast = NSScreen.screens.count >= Self.bigCastThreshold
        setFeed(!busy && !bigCast)
        if VirtualMouse.ghostMouseEnabled { events?.startMouseMonitors() }
        events?.startKeyMonitors()
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

    /// Key the stage on `screen` (focus-follows-cursor).
    func focusWindow(on screen: NSScreen) {
        ensemble.focusWindow(on: screen)
    }

    func hide() {
        capture.stop()
        cancelFeedWatchdog()
        events?.stopMouseMonitors()
        events?.stopKeyMonitors()
        activeDisplayID = nil
        ensemble.dismiss()
    }

    // MARK: - Ghost mouse feed (see VirtualMouse.swift)

    /// One cursor sample: reproject the chrome only when the active screen changed;
    /// always move the ghost mouse / beacon / tooltip.
    private func mouseDidMove() {
        guard isVisible else { return }
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let activeID = GlobalMap.hostDisplayID(cursor: cursor, planeFirst: state.planeDisplays,
                                               all: state.displays)
        let active = activeID.flatMap { id in stages.first { $0.centerID == id } }
        // The cursor in the active stage's view coords, derived from the same CGEvent
        // sample as `cursor` so the ghost and beacon can't disagree about where it is.
        var cursorActivePoint: CGPoint?
        if let activeID, let window = windows[activeID] {
            let up = GlobalMap.cocoaPoint(fromCG: cursor)
            // The stage is flipped (y-down from the window top).
            cursorActivePoint = CGPoint(x: up.x - window.frame.minX, y: window.frame.maxY - up.y)
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
            for stage in stages { stage.renderChrome(active: stage === active ? nil : active) }
        }
        // The hovered control's tooltip trails the (ghost) cursor on every stage.
        let tip = active.flatMap { $0.hoveredTooltip() }
        for stage in stages {
            stage.updateGhostArrow(cursorActivePoint: cursorActivePoint, isActive: stage === active)
            stage.updatePlaneMarker(cursor: cursor, hostID: activeID)
            stage.updateTooltip(text: tip, cursorActivePoint: cursorActivePoint)
        }
    }

    /// Re-interpret the OS layout into the shared plane and repaint (external change).
    /// `force` re-reads the plane even when it already matches (e.g. after Reset).
    func refresh(displays: [DisplaySnapshot], force: Bool = false) {
        guard isVisible else { return }
        state.update(with: displays, force: force)
        rebuild()   // screens may have changed
        stages.forEach { $0.refresh() }
        rerenderChrome()
    }

    /// Refresh the unified chrome metrics (see `ArrangerState`).
    private func updateChromeMetrics() {
        let insets = GlobalMap.uniformInsets()
        state.uniformDockInset = insets.dock
        state.uniformMenuBarInset = insets.menuBar
        state.minScreenExtent = insets.minExtent
    }

    private func rebuild() {
        updateChromeMetrics()
        ensemble.rebuild()
    }

    /// Dress a fresh ensemble window: glass backdrop + this screen's stage.
    private func dress(_ window: NSWindow, centerID: CGDirectDisplayID) {
        // Backdrop: native Liquid Glass on macOS 26, behind-window blur below. The
        // stage (with its own dim wash) sits on top.
        let fullFrame = CGRect(origin: .zero, size: window.frame.size)
        let stage = Stage(state: state, frame: fullFrame)
        stage.centerID = centerID
        stage.autoresizingMask = [.width, .height]
        stage.onLayout = { [weak self] in self?.rerenderChrome() }

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
            host.addSubview(stage)            // stage on top, at the true full frame
            window.contentView = host
        } else {
            let blur = NSVisualEffectView(frame: fullFrame)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            blur.addSubview(stage)
            window.contentView = blur
        }
        window.makeFirstResponder(stage)
        stages.append(stage)
    }

    fileprivate static func keyInput(_ e: NSEvent) -> KeyInput {
        let f = e.modifierFlags
        return KeyInput(code: e.keyCode, chars: e.charactersIgnoringModifiers,
                        cmd: f.contains(.command), shift: f.contains(.shift),
                        isRepeat: e.isARepeat)
    }

}
