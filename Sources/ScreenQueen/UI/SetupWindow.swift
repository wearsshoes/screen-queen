import SwiftUI
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
/// from the menu ("Backstage Pass…"). The window is rebuilt per showing so the SwiftUI
/// view's state (grants seen at open) starts fresh each time.
@MainActor
final class SetupWindow {

    /// Called when the window closes (first run uses this to raise the curtain).
    var onDismiss: (() -> Void)?

    private var window: NSWindow?

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SetupView(done: { [weak self] in
            self?.window?.close()
        }))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = Copy.setupTitle
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                self?.onDismiss?()
            }
        }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}

/// The Backstage Pass content: headline, per-permission rows with live readouts,
/// launch-at-login, and the footer with the conditional relaunch offer.
struct SetupView: View {
    let done: () -> Void

    /// Grant states when the view appeared, to notice a mid-session grant (which macOS
    /// usually only honors after an app restart → surface the relaunch button).
    /// @State so it survives re-renders — a plain let would re-capture post-grant.
    @State private var grantedOnOpen = (ax: SetupWindow.accessibilityGranted,
                                        sr: SetupWindow.screenRecordingGranted)

    @State private var ax = SetupWindow.accessibilityGranted
    @State private var sr = SetupWindow.screenRecordingGranted
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    // Permissions flip in System Settings, outside our process, with no notification
    // for Accessibility — poll while visible so the readout is live.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Copy.setupTitle)
                .font(Font(DragFont.script(size: 34)))
                .foregroundStyle(Color(nsColor: .systemPink))
            Text(Copy.setupIntro)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Divider()
            permissionRow(name: Copy.setupAXName, why: Copy.setupAXWhy, granted: ax,
                          grant: grantAccessibility)
            permissionRow(name: Copy.setupSRName, why: Copy.setupSRWhy, granted: sr,
                          grant: grantScreenRecording)
            Divider()
            Toggle(Copy.setupLoginToggle, isOn: loginBinding)
            HStack {
                if showRelaunch {
                    Button(Copy.setupRelaunch, action: relaunch)
                }
                Spacer()
                Button(Copy.setupDone, action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 480)
        .onReceive(tick) { _ in
            ax = SetupWindow.accessibilityGranted
            sr = SetupWindow.screenRecordingGranted
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    /// One permission row: bold name + live status on the first line, the why-line
    /// beneath, and a trailing Grant button (hidden once granted).
    private func permissionRow(name: String, why: String, granted: Bool,
                               grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .bold))
                    Text(granted ? Copy.setupGranted : Copy.setupNotYet)
                        .font(.system(size: 12))
                        .foregroundStyle(granted ? Color(nsColor: .systemGreen) : .secondary)
                }
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(Copy.setupGrant, action: grant)
            }
        }
    }

    // A grant that happened while we're open usually needs a relaunch to take —
    // global monitors and ScreenCaptureKit check at process start. Only offer it
    // when running as a real .app (the bare dev binary can't relaunch itself).
    private var showRelaunch: Bool {
        let newlyGranted = (!grantedOnOpen.ax && ax) || (!grantedOnOpen.sr && sr)
        return newlyGranted && Bundle.main.bundlePath.hasSuffix(".app")
    }

    // SMAppService needs a real .app bundle; the bare dev binary throws — leave the
    // toggle put rather than lie about the state.
    private var loginBinding: Binding<Bool> {
        Binding(get: { loginEnabled }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginEnabled = on
            } catch {
                NSSound.beep()
            }
        })
    }

    private func grantAccessibility() {
        // Fire the system prompt (only ever shows once per app), then open the pane —
        // after the first decline, the pane is the only way in.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        openSettings("Privacy_Accessibility")
    }

    private func grantScreenRecording() {
        CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
