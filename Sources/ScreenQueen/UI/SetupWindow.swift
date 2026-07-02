import AppKit
import ApplicationServices
import ServiceManagement

/// "Backstage Pass": the one-sitting permissions walkthrough. Every key she needs —
/// Accessibility (the global hotkey) and Screen Recording (the live tile feed) — on one
/// screen, each with a line on exactly why she's asking and a live granted/not-yet
/// readout, instead of macOS ambushing the user with system prompts one feature at a
/// time. Also home to the launch-at-login toggle, and a relaunch button when a permission
/// granted mid-session needs an app restart to stick.
///
/// Shown automatically on first run (before the arranger's entrance) and any time after
/// from the menu ("Backstage Pass…").
@MainActor
final class SetupWindow {

    /// Called when the window closes (first run uses this to raise the curtain).
    var onDismiss: (() -> Void)?

    private var window: NSWindow?
    private var pollTimer: Timer?

    // Live-updating widgets, refreshed by the poll while the window is up.
    private var axStatus: NSTextField?
    private var axGrant: NSButton?
    private var srStatus: NSTextField?
    private var srGrant: NSButton?
    private var loginToggle: NSButton?
    private var relaunchButton: NSButton?

    /// Grant states when the window opened, to notice a mid-session grant (which macOS
    /// usually only honors after an app restart → surface the relaunch button).
    private var grantedOnOpen: (ax: Bool, sr: Bool) = (false, false)

    // MARK: - Permission state

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - Presenting

    func show() {
        if window == nil { build() }
        grantedOnOpen = (Self.accessibilityGranted, Self.screenRecordingGranted)
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        pollTimer?.invalidate()
        // Permissions flip in System Settings, outside our process, with no notification
        // for Accessibility — poll while visible so the readout is live.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        onDismiss?()
    }

    // MARK: - Actions

    @objc private func grantAccessibility() {
        // Fire the system prompt (only ever shows once per app), then open the pane —
        // after the first decline, the pane is the only way in.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        openSettings("Privacy_Accessibility")
    }

    @objc private func grantScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        // SMAppService needs a real .app bundle; the bare dev binary throws — revert the
        // checkbox rather than lie about the state.
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = sender.state == .on ? .off : .on
            NSSound.beep()
        }
    }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func done() { close() }

    // MARK: - Live readout

    private func refresh() {
        style(axStatus, axGrant, granted: Self.accessibilityGranted)
        style(srStatus, srGrant, granted: Self.screenRecordingGranted)
        loginToggle?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // A grant that happened while we're open usually needs a relaunch to take —
        // global monitors and ScreenCaptureKit check at process start. Only offer it
        // when running as a real .app (the bare dev binary can't relaunch itself).
        let newlyGranted = (!grantedOnOpen.ax && Self.accessibilityGranted)
            || (!grantedOnOpen.sr && Self.screenRecordingGranted)
        relaunchButton?.isHidden = !(newlyGranted && Bundle.main.bundlePath.hasSuffix(".app"))
    }

    private func style(_ status: NSTextField?, _ grant: NSButton?, granted: Bool) {
        status?.stringValue = granted ? Copy.setupGranted : Copy.setupNotYet
        status?.textColor = granted ? .systemGreen : .secondaryLabelColor
        grant?.isHidden = granted
    }

    // MARK: - Building the window

    private func build() {
        let headline = NSTextField(labelWithString: Copy.setupTitle)
        headline.font = DragFont.script(size: 34)
        headline.textColor = .systemPink

        let intro = NSTextField(wrappingLabelWithString: Copy.setupIntro)
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 420

        let (axRow, axS, axB) = permissionRow(name: Copy.setupAXName, why: Copy.setupAXWhy,
                                              action: #selector(grantAccessibility))
        axStatus = axS; axGrant = axB
        let (srRow, srS, srB) = permissionRow(name: Copy.setupSRName, why: Copy.setupSRWhy,
                                              action: #selector(grantScreenRecording))
        srStatus = srS; srGrant = srB

        let login = NSButton(checkboxWithTitle: Copy.setupLoginToggle,
                             target: self, action: #selector(toggleLogin(_:)))
        loginToggle = login

        let relaunch = NSButton(title: Copy.setupRelaunch, target: self, action: #selector(relaunch))
        relaunch.bezelStyle = .rounded
        relaunch.isHidden = true
        relaunchButton = relaunch

        let doneButton = NSButton(title: Copy.setupDone, target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [relaunch, NSView(), doneButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [headline, intro, separator(), axRow, srRow,
                                        separator(), login, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(4, after: headline)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        // The footer spans the full width so Done can sit at the trailing edge.
        footer.translatesAutoresizingMaskIntoConstraints = false
        stack.setVisibilityPriority(.mustHold, for: footer)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = Copy.setupTitle
        w.isReleasedWhenClosed = false
        w.contentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 480),
            footer.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 24),
        ])
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pollTimer?.invalidate(); self?.onDismiss?() }
        }
    }

    /// One permission row: bold name + live status on the first line, the why-line
    /// beneath, and a trailing Grant button (hidden once granted).
    private func permissionRow(name: String, why: String,
                               action: Selector) -> (NSView, NSTextField, NSButton) {
        let title = NSTextField(labelWithString: name)
        title.font = .boldSystemFont(ofSize: 13)
        let status = NSTextField(labelWithString: Copy.setupNotYet)
        status.font = .systemFont(ofSize: 12)
        let titleLine = NSStackView(views: [title, status])
        titleLine.orientation = .horizontal
        titleLine.spacing = 8

        let whyLabel = NSTextField(wrappingLabelWithString: why)
        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .secondaryLabelColor
        whyLabel.preferredMaxLayoutWidth = 330

        let text = NSStackView(views: [titleLine, whyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let grant = NSButton(title: Copy.setupGrant, target: self, action: action)
        grant.bezelStyle = .rounded

        let row = NSStackView(views: [text, NSView(), grant])
        row.orientation = .horizontal
        row.alignment = .top
        return (row, status, grant)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
