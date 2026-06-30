import AppKit
import CoreGraphics

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
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { delegate.refresh() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var canvas: ArrangementCanvas!
    private let overlay = OverlayController()
    private var overlayMenuItem: NSMenuItem!
    private let calibrationController = CalibrationController()
    private var revertButton: NSButton!

    // Live-drag / revert state.
    private var isLiveDragging = false
    private var preDragOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var preDragMainID: CGDirectDisplayID?
    private var revertOrigins: [CGDirectDisplayID: CGPoint]?
    private var wasOverlayVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupWindow()

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, context)

        refresh()
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, context)
    }

    // MARK: - Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖥"

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Arrangement", action: #selector(showWindow), keyEquivalent: "")
        overlayMenuItem = NSMenuItem(title: "Show Reference Bars",
                                     action: #selector(toggleOverlays(_:)), keyEquivalent: "b")
        menu.addItem(overlayMenuItem)
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit screenmonger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func setupWindow() {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 460)
        canvas = ArrangementCanvas(frame: frame)
        canvas.autoresizingMask = [.width, .height]

        let container = NSView(frame: frame)
        container.addSubview(canvas)

        revertButton = NSButton(title: "Revert", target: self, action: #selector(revertTapped))
        revertButton.bezelStyle = .rounded
        revertButton.translatesAutoresizingMaskIntoConstraints = false
        revertButton.isHidden = true
        container.addSubview(revertButton)
        NSLayoutConstraint.activate([
            revertButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            revertButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        ])

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "screenmonger — Arrangement"
        window.contentView = container
        window.center()
        window.isReleasedWhenClosed = false

        canvas.onCommit = { [weak self] origins in
            self?.commitArrangement(origins)
        }
        canvas.onDragUpdate = { [weak self] origins in
            self?.dragUpdate(origins)
        }
        canvas.onSetMain = { [weak self] id in
            self?.setMainDisplay(id)
        }
        canvas.onSetMode = { [weak self] id, mode in
            self?.setMode(id, mode)
        }
        canvas.onCalibrate = { [weak self] id in
            self?.calibrate(id)
        }
        canvas.onCalibrateVisual = { [weak self] id in
            self?.calibrateVisual(id)
        }
        canvas.onResetCalibration = { [weak self] id in
            self?.resetCalibration(id)
        }
        calibrationController.onComplete = { [weak self] in self?.refresh() }
    }

    /// Visual match-the-boxes calibration against a trusted reference display.
    private func calibrateVisual(_ id: CGDirectDisplayID) {
        let displays = DisplayManager.snapshot()
        guard let target = displays.first(where: { $0.id == id }) else { return }
        let candidates = displays.filter { $0.id != id && $0.pointsPerInch != nil }
        let reference = candidates.first(where: { $0.isBuiltin })
            ?? candidates.first(where: { $0.physicalSizeIsCalibrated })
            ?? candidates.first
        guard let reference else {
            calibrate(id) // no trusted reference available — fall back to manual entry
            return
        }
        // Avoid the reference boxes cluttering the comparison.
        if overlay.isVisible { overlay.hide(); overlayMenuItem.state = .off }
        calibrationController.begin(target: target, reference: reference)
    }

    // MARK: - Calibration

    /// Prompt for the display's true diagonal size (EDID can't be trusted) and
    /// store an override keyed to that physical monitor.
    private func calibrate(_ id: CGDirectDisplayID) {
        guard let d = DisplayManager.snapshot().first(where: { $0.id == id }) else { return }

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

    /// Switch a display's resolution, then confirm-or-revert. The revert really
    /// matters here: a bad mode can leave a screen black.
    private func setMode(_ id: CGDirectDisplayID, _ mode: CGDisplayMode) {
        let previous = CGDisplayCopyDisplayMode(id)
        guard DisplayManager.applyMode(mode, to: id) else {
            refresh()
            return
        }
        refresh()
        if !confirmKeep(), let previous {
            DisplayManager.applyMode(previous, to: id)
            refresh()
        }
    }

    /// Make `id` the main display by shifting the whole arrangement so that
    /// display sits at the global origin (0,0) — CoreGraphics treats the display
    /// at (0,0) as main. This is the one path that deliberately changes the main
    /// display, so it confirms with the auto-revert modal.
    private func setMainDisplay(_ id: CGDirectDisplayID) {
        let snapshot = DisplayManager.snapshot()
        guard let target = snapshot.first(where: { $0.id == id }), !target.isMain else { return }
        let before = originMap(of: snapshot)
        let dx = -target.bounds.origin.x
        let dy = -target.bounds.origin.y
        let origins = Dictionary(uniqueKeysWithValues: snapshot.map {
            ($0.id, CGPoint(x: $0.bounds.origin.x + dx, y: $0.bounds.origin.y + dy))
        })

        guard DisplayManager.applyOrigins(origins, permanent: true) else { refresh(); return }
        refresh()
        if !confirmKeep() {
            DisplayManager.applyOrigins(before, permanent: true)
            refresh()
        }
        hideRevert()
    }

    // MARK: - Arrangement commit

    /// Preview a placement during a drag — *without* touching the real displays
    /// (a CG reconfigure per slot is far too slow). We move only our own things:
    /// the canvas tiles and the reference-bar overlay, fed a prospective layout.
    /// The real reconfigure happens once on drop. Reference bars auto-appear at
    /// the start of a drag.
    private func dragUpdate(_ origins: [CGDirectDisplayID: CGPoint]) {
        if !isLiveDragging {
            isLiveDragging = true
            let snap = DisplayManager.snapshot()
            preDragOrigins = originMap(of: snap)
            preDragMainID = snap.first(where: { $0.isMain })?.id
            wasOverlayVisible = overlay.isVisible
        }
        let prospective = prospectiveSnapshot(origins)
        if overlay.isVisible {
            overlay.update(with: prospective)
        } else {
            overlay.show(with: prospective)
        }
    }

    /// Finalize a drag: now apply the layout to the real displays, once. A drag
    /// never changes the main display (it's pinned), so no modal here.
    private func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        let beforeOrigins = preDragOrigins
        isLiveDragging = false

        guard DisplayManager.applyOrigins(pinningMain(origins), permanent: true) else {
            refresh()
            return
        }
        // Restore the overlay to its pre-drag visibility.
        if !wasOverlayVisible {
            overlay.hide()
            overlayMenuItem.state = .off
        }
        refresh()

        if originsEqual(originMap(of: DisplayManager.snapshot()), beforeOrigins) {
            hideRevert() // dragged back to where it started
        } else {
            showRevert(to: beforeOrigins)
        }
    }

    /// The real snapshot with origins replaced by the (main-pinned) drag layout,
    /// for previewing without reconfiguring hardware.
    private func prospectiveSnapshot(_ origins: [CGDirectDisplayID: CGPoint]) -> [DisplaySnapshot] {
        let pinned = pinningMain(origins)
        return DisplayManager.snapshot().map { d in
            pinned[d.id].map { d.movedTo(origin: $0) } ?? d
        }
    }

    /// Translate an arrangement so the current main display stays at global
    /// (0,0) — CoreGraphics keys the main display off (0,0), so this guarantees
    /// the main display never changes during a rearrange.
    private func pinningMain(_ origins: [CGDirectDisplayID: CGPoint]) -> [CGDirectDisplayID: CGPoint] {
        guard let mainID = preDragMainID, let offset = origins[mainID] else { return origins }
        return origins.mapValues { CGPoint(x: $0.x - offset.x, y: $0.y - offset.y) }
    }

    @objc private func revertTapped() {
        guard let target = revertOrigins else { return }
        DisplayManager.applyOrigins(target)
        refresh()
        hideRevert()
    }

    private func showRevert(to origins: [CGDirectDisplayID: CGPoint]) {
        revertOrigins = origins
        revertButton.isHidden = false
    }

    private func hideRevert() {
        revertOrigins = nil
        revertButton.isHidden = true
    }

    private func originMap(of snapshot: [DisplaySnapshot]) -> [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.bounds.origin) })
    }

    private func originsEqual(_ a: [CGDirectDisplayID: CGPoint], _ b: [CGDirectDisplayID: CGPoint]) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in a {
            guard let w = b[k], abs(v.x - w.x) < 1, abs(v.y - w.y) < 1 else { return false }
        }
        return true
    }

    /// Modal "Keep this arrangement?" with a countdown that auto-reverts.
    private func confirmKeep(seconds: Int = 12) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Keep this arrangement?"
        alert.informativeText = "Reverting to the previous layout automatically…"
        let keep = alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Revert")

        var remaining = seconds
        keep.title = "Keep (\(remaining))"
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            remaining -= 1
            if remaining <= 0 {
                t.invalidate()
                NSApp.abortModal()
            } else {
                keep.title = "Keep (\(remaining))"
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        timer.invalidate()
        return response == .alertFirstButtonReturn
    }

    // MARK: - Actions

    @objc func refresh() {
        let displays = DisplayManager.snapshot()
        // Mid-drag, the canvas owns its working state; don't clobber it. The
        // overlay still updates so the reference bars track live.
        if !isLiveDragging { canvas.update(with: displays) }
        overlay.update(with: displays)
    }

    @objc func toggleOverlays(_ sender: NSMenuItem) {
        overlay.toggle(with: DisplayManager.snapshot())
        sender.state = overlay.isVisible ? .on : .off
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
