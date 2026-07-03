import AppKit
import IOKit

/// The app's one owner of NSEvent/CGEvent monitors and cursor polling. Everything
/// event-shaped comes out of here as a closure call: the ⌘⌥F1 hotkey toggle, the ghost
/// mouse's cursor samples, and focus-follows-cursor. Nothing else in the app installs a
/// monitor. (The known upgrade — a consuming CGEventTap — would slot in behind these
/// same closures; see TODO.)
@MainActor
final class EventPlumbing {

    // MARK: - Hotkey (⌘⌥F1)

    var onHotkeyToggle: (() -> Void)?
    private var hotkeyMonitors: [Any] = []
    /// Debounce: the same press can hit both the local and global monitors (or
    /// auto-repeat), which double-toggled. Ignore repeats within a short window.
    private var lastHotkeyToggle: TimeInterval = 0

    /// ⌘⌥ + Brightness-Down (the F1 key on Mac keyboards). That key is a
    /// *system-defined* media event, not a plain keyDown. A local monitor catches it
    /// while our app is focused, a global one otherwise.
    func installHotkey() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods == [.command, .option] else { return false }
            // data1: high 16 bits = key code, low bits = state; 0x0A = key down.
            let keyCode = (event.data1 & 0xFFFF0000) >> 16
            let keyDown = (event.data1 & 0xFF00) >> 8 == 0x0A
            guard keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN, keyDown else { return false }
            guard let self else { return true }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastHotkeyToggle > 0.25 else { return true }
            self.lastHotkeyToggle = now
            self.onHotkeyToggle?()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: { _ = handler($0) }) {
            hotkeyMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { handler($0) ? nil : $0 }) {
            hotkeyMonitors.append(l)
        }
    }

    // MARK: - Cursor samples (the ghost-mouse feed)

    /// Fired on every mouse move/drag while the mouse monitors run (and by the
    /// slider-drag timer). The consumer samples the cursor itself via CGEvent.
    var onMouseSample: (() -> Void)?
    private var mouseMonitors: [Any] = []

    /// Follow the real mouse: a global monitor for other apps' screens, a local one
    /// for our own overlays. Idempotent.
    func startMouseMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                           .rightMouseDragged, .otherMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.onMouseSample?()
        }) { mouseMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.onMouseSample?()
            return event
        }) { mouseMonitors.append(l) }
    }

    func stopMouseMonitors() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors.removeAll()
        setSliderDragging(false)
    }

    /// A slider drag runs a modal tracking loop that starves the mouse monitors (and
    /// the value-preview only notifies on detent changes), so drive the samples from a
    /// timer while held — in `.common` mode so it ticks during `.eventTracking`.
    private var sliderDragTimer: Timer?

    func setSliderDragging(_ dragging: Bool) {
        sliderDragTimer?.invalidate(); sliderDragTimer = nil
        guard dragging else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMouseSample?() }
        }
        RunLoop.main.add(t, forMode: .common)
        sliderDragTimer = t
    }

    // MARK: - Focus follows the cursor

    /// With one overlay (or calibration panel) per screen, keyboard input goes to the
    /// *key* window — so the screen you're mousing over should be the one listening, no
    /// click required. Mechanism: a light poll of `NSEvent.mouseLocation` doing
    /// screen-*change* detection only — no window needs `acceptsMouseMovedEvents`.
    /// Calibration deliberately owns none of this (`CalibrationController.focusPanel(on:)`
    /// is safe to call liberally).

    // Wired once by the AppDelegate.
    var isCalibrationActive: () -> Bool = { false }
    var focusCalibration: (NSScreen) -> Void = { _ in }
    var isArrangerVisible: () -> Bool = { false }
    var focusArranger: (NSScreen) -> Void = { _ in }

    private var focusTimer: Timer?
    /// The cursor's screen at the last tick, by frame — NSScreen instances aren't
    /// stable across calls, so identity comparisons would retrigger endlessly.
    private var lastScreenFrame: NSRect?

    /// Start following (idempotent). Call whenever a followable surface appears
    /// (arranger shown, calibration begun); the timer retires itself when none is left.
    func beginFocusFollowing() {
        guard focusTimer == nil else { return }
        lastScreenFrame = nil   // re-key on the first tick even if the screen "didn't change"
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusTick() }
        }
    }

    private func focusTick() {
        let calibrating = isCalibrationActive()
        guard calibrating || isArrangerVisible() else {
            focusTimer?.invalidate(); focusTimer = nil; lastScreenFrame = nil
            return
        }
        // Never move focus while a button is down — a tape or tile mid-drag across a
        // seam must keep its window key until it's released.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }),
              screen.frame != lastScreenFrame else { return }
        lastScreenFrame = screen.frame
        if calibrating { focusCalibration(screen) } else { focusArranger(screen) }
    }

    // MARK: - Teardown

    func teardown() {
        hotkeyMonitors.forEach { NSEvent.removeMonitor($0) }
        hotkeyMonitors.removeAll()
        stopMouseMonitors()
        focusTimer?.invalidate(); focusTimer = nil
    }
}
