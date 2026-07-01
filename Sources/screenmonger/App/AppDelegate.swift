import AppKit
import CoreGraphics
import IOKit
import IOKit

/// C callback for display hotplug / reconfiguration. Bounces back to the
/// AppDelegate (carried via the `userInfo` context pointer) on the main queue.
private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // `beginConfiguration` fires once before the batch; ignore it to avoid
    // refreshing against a half-applied state.
    if flags.contains(.beginConfigurationFlag) { return }
    // The callback fires once per display in a batch; coalesce into one refresh so
    // we relayout the arranger a single time (no per-display shuffle).
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { delegate.scheduleRefresh() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let arranger = ArrangementWindows()
    private let calibrationController = CalibrationController()

    private var isLiveDragging = false
    /// Snapshot captured when the arranger was opened, for "Reset".
    private var baselineOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var baselineModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    private var hotkeyMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityIfNeeded()   // needed to see the global ⌘⌥F1 hotkey
        setupMenuBar()
        setupArranger()
        setupHotkey()

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, context)

        refresh()
        showWindow()
    }

    /// Prompt for Accessibility permission (once), which macOS requires for the global
    /// key monitor to observe the hotkey while other apps are focused.
    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// ⌘⌥ + Brightness-Down (the F1 key on Mac keyboards) toggles the arranger from
    /// anywhere. That key is a *system-defined* media event, not a plain keyDown. A
    /// local monitor catches it while the arranger is focused, a global one otherwise.
    private func setupHotkey() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == [.command, .option] else { return false }
            // data1: high 16 bits = key code, low bits = state; 0x0A = brightness-down.
            let keyCode = (event.data1 & 0xFFFF0000) >> 16
            let keyDown = (event.data1 & 0xFF00) >> 8 == 0x0A
            guard keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN, keyDown else { return false }
            self?.toggleArranger()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { _ = handler($0) }) {
            hotkeyMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { handler($0) ? nil : $0 }) {
            hotkeyMonitors.append(l)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, context)
        hotkeyMonitors.forEach { NSEvent.removeMonitor($0) }
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖥"
        // Left-click opens the arranger; right-click shows a menu (just Quit).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Arrangement  (⌘⌥F1)", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit screenmonger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }()

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if rightClick {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)   // pop the menu
            statusItem.menu = nil                  // detach so the next left-click hits our action
        } else {
            toggleArranger()
        }
    }

    /// Open the arranger, or close it if it's already open.
    @objc private func toggleArranger() {
        if arranger.isVisible { dismissArranger() } else { showWindow() }
    }

    private func setupArranger() {
        let s = arranger.state
        s.onCommit = { [weak self] origins in self?.commitArrangement(origins) }
        s.onSetMain = { [weak self] id in self?.setMainDisplay(id) }
        s.onSetResolution = { [weak self] id, mode, origins in self?.setResolution(id, mode, origins) }
        s.onCalibrate = { [weak self] id in self?.calibrate(id) }
        s.onCalibrateVisual = { [weak self] id in self?.calibrateVisual(id) }
        s.onResetCalibration = { [weak self] id in self?.resetCalibration(id) }
        s.onDismiss = { [weak self] in self?.dismissArranger() }
        s.onReset = { [weak self] in self?.resetToBaseline() }
        // A live plane change (drag / nudge / align) marks the session live so the
        // reconfig callback doesn't clobber the working plane.
        let priorChanged = s.changed
        s.changed = { [weak self] in self?.isLiveDragging = true; priorChanged?() }
        calibrationController.onComplete = { [weak self] in self?.refresh() }
    }

    /// Visual match-the-boxes calibration against a trusted reference display.
    private func calibrateVisual(_ id: CGDirectDisplayID) {
        let displays = DisplayManager.snapshot()
        guard let target = displays.first(where: { $0.id == id }), !target.isBuiltin else { return }
        let candidates = displays.filter { $0.id != id && $0.pointsPerInch != nil }
        let reference = candidates.first(where: { $0.isBuiltin })
            ?? candidates.first(where: { $0.physicalSizeIsCalibrated })
            ?? candidates.first
        guard let reference else {
            calibrate(id) // no trusted reference available — fall back to manual entry
            return
        }
        // Dismiss the arranger overlay so it doesn't clutter the calibration windows.
        dismissArranger()
        calibrationController.begin(target: target, reference: reference)
    }

    // MARK: - Calibration

    /// Prompt for the display's true diagonal size (EDID can't be trusted) and
    /// store an override keyed to that physical monitor.
    private func calibrate(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }), !d.isBuiltin else { return }

        let alert = NSAlert()
        alert.messageText = "Calibrate \(d.name)"
        alert.informativeText = "Enter the screen's diagonal size in inches (corner to corner of the visible area). EDID currently reports \(String(format: "%.1f", d.diagonalInches))\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 15.4"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let inches = Double(field.stringValue), inches > 1 else { return }

        let mm = CalibrationStore.sizeMM(diagonalInches: inches,
                                         pixelWidth: Int(d.pixelSize.width),
                                         pixelHeight: Int(d.pixelSize.height))
        CalibrationStore.setOverride(mm, for: d.fingerprint)
        refresh()
    }

    private func resetCalibration(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }) else { return }
        CalibrationStore.clearOverride(for: d.fingerprint)
        refresh()
    }

    /// Apply a reconfiguration and offer a countdown "Revert" at the bottom of every
    /// screen (the arranger is on all of them, so there's no unusable state to trap
    /// the user). `apply` returns false if it couldn't even start.
    private func applyRevertable(apply: () -> Bool, revert: @escaping () -> Void) {
        guard preservingCursor(apply) else { refresh(); return }
        refresh()
        arranger.state.pendingRevert = { [weak self] in
            self?.preservingCursor { revert(); return true }; self?.refresh()
        }
        arranger.state.notify()
    }

    // MARK: - Cursor preservation

    /// Run `body` (a reconfiguration), keeping the cursor at the same fractional spot
    /// within whatever physical display it was on. macOS often teleports the cursor
    /// across a reconfig; this puts it back where the hand expects it.
    @discardableResult
    private func preservingCursor(_ body: () -> Bool) -> Bool {
        // Cursor in global CG coords (top-left origin), and its display + fraction.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let beforeID = displayContaining(cursor)
        let beforeFraction = beforeID.flatMap { id -> CGPoint? in
            let b = CGDisplayBounds(id)
            guard b.width > 0, b.height > 0 else { return nil }
            return CGPoint(x: (cursor.x - b.minX) / b.width, y: (cursor.y - b.minY) / b.height)
        }

        let ok = body()

        // Warp back to the same fraction of that display's (possibly moved/resized) bounds.
        if let id = beforeID, let f = beforeFraction {
            let b = CGDisplayBounds(id)
            let target = CGPoint(x: b.minX + f.x * b.width, y: b.minY + f.y * b.height)
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)   // resync after the warp
        }
        return ok
    }

    private func displayContaining(_ p: CGPoint) -> CGDirectDisplayID? {
        DisplayManager.snapshot().first { CGDisplayBounds($0.id).contains(p) }?.id
    }

    /// Change a display's resolution, preserving alignment: apply the new mode
    /// *and* re-set the arrangement so the display stays where the plane put it at
    /// the new point size. Reverts both (undoable) if a bad mode blacks a screen.
    private func setResolution(_ id: CGDirectDisplayID, _ mode: CGDisplayMode,
                               _ origins: [CGDirectDisplayID: CGPoint]) {
        isLiveDragging = false
        let snap = DisplayManager.snapshot()
        let previousMode = CGDisplayCopyDisplayMode(id)
        let previousOrigins = originMap(of: snap)
        let mainID = snap.first(where: { $0.isMain })?.id
        applyRevertable(apply: {
            guard DisplayManager.applyMode(mode, to: id) else { return false }
            DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
            return true
        }, revert: {
            if let previousMode { DisplayManager.applyMode(previousMode, to: id) }
            DisplayManager.applyOrigins(previousOrigins, permanent: true)
        })
    }

    /// Make `id` the main display. The arrangement geometry is the current plane; we
    /// just shift it so `id` sits at (0,0) (CoreGraphics keys main off the origin), so
    /// the plane — and thus the tiles — don't change.
    private func setMainDisplay(_ id: CGDirectDisplayID) {
        let snapshot = DisplayManager.snapshot()
        guard snapshot.first(where: { $0.id == id })?.isMain == false,
              let origins = arranger.state.originsMakingMain(id) else { return }
        isLiveDragging = false
        let before = originMap(of: snapshot)
        applyRevertable(apply: { DisplayManager.applyOrigins(origins, permanent: true) },
                        revert: { DisplayManager.applyOrigins(before, permanent: true) })
    }

    // MARK: - Arrangement commit

    /// Finalize a manipulation (drag or keyboard): apply to the real displays once,
    /// pinning the current main so it never changes. Works for both mouse and keyboard
    /// because neither reconfigures hardware until here, so the live snapshot is still
    /// the "before" state.
    private func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        let snap = DisplayManager.snapshot()
        let mainID = snap.first(where: { $0.isMain })?.id
        isLiveDragging = false
        // Rearranging can't strand the user (the arranger is on every screen), so no
        // revert offer — only main/resolution changes arm one.
        let pinned = pin(origins, mainID: mainID)
        preservingCursor { DisplayManager.applyOrigins(pinned, permanent: true) }
        refresh()
    }

    /// Translate an arrangement so `mainID` stays at global (0,0) — CoreGraphics
    /// keys the main display off (0,0), so this guarantees main never changes.
    private func pin(_ origins: [CGDirectDisplayID: CGPoint], mainID: CGDirectDisplayID?) -> [CGDirectDisplayID: CGPoint] {
        guard let mainID, let offset = origins[mainID] else { return origins }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }

    private func originMap(of snapshot: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.bounds.origin) })
    }

    // MARK: - Actions

    @objc func refresh() {
        // Mid-manipulation the shared plane owns the working state; don't clobber it.
        guard !isLiveDragging else { return }
        let displays = DisplayManager.snapshot()
        arranger.refresh(displays: displays, colors: DisplayGraph.colors(displays))
    }

    private var refreshScheduled = false

    /// Coalesce the per-display reconfig callbacks into one refresh at the end of the
    /// run loop turn, so a batch (e.g. a main-display change) relayouts just once.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    @objc func showWindow() {
        let displays = DisplayManager.snapshot()
        // Capture the current layout + resolutions as the "Reset" baseline.
        baselineOrigins = originMap(of: displays)
        baselineModes = Dictionary(uniqueKeysWithValues: displays.compactMap { d in
            CGDisplayCopyDisplayMode(d.id).map { (d.id, $0) }
        })
        arranger.show(displays: displays, colors: DisplayGraph.colors(displays))
    }

    /// Restore positions, resolutions, and main to the baseline captured on open.
    private func resetToBaseline() {
        arranger.state.pendingRevert = nil
        arranger.state.clearUndo()
        preservingCursor {
            for (id, mode) in baselineModes { DisplayManager.applyMode(mode, to: id) }
            return DisplayManager.applyOrigins(baselineOrigins, permanent: true)
        }
        // Force a re-interpret so the plane returns to the (possibly edited-equivalent)
        // baseline layout, and repaint.
        let displays = DisplayManager.snapshot()
        arranger.refresh(displays: displays, colors: DisplayGraph.colors(displays), force: true)
    }

    private func dismissArranger() {
        arranger.hide()
    }
}
