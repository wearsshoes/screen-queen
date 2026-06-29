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
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit screenmonger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func setupWindow() {
        canvas = ArrangementCanvas(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "screenmonger — Arrangement"
        window.contentView = canvas
        window.center()
        window.isReleasedWhenClosed = false

        canvas.onCommit = { [weak self] origins in
            self?.commitArrangement(origins)
        }
    }

    // MARK: - Arrangement commit

    /// Apply a new arrangement, then ask the user to keep it — auto-reverting to
    /// the previous layout if they don't confirm in time. The revert is the
    /// safety net that becomes essential once resolution changes (which can
    /// blank a screen) land in Phase 3.
    private func commitArrangement(_ origins: [CGDirectDisplayID: CGPoint]) {
        let previous = DisplayManager.snapshot()
        let previousOrigins = Dictionary(
            uniqueKeysWithValues: previous.map { ($0.id, $0.bounds.origin) }
        )

        guard DisplayManager.applyOrigins(origins) else {
            refresh() // apply failed — snap visuals back to reality
            return
        }
        refresh()

        if !confirmKeep() {
            DisplayManager.applyOrigins(previousOrigins)
            refresh()
        }
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
        canvas.update(with: DisplayManager.snapshot())
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
