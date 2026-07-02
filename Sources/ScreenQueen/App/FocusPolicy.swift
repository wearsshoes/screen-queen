import AppKit

/// Focus follows the cursor, app-wide. With one overlay (or calibration panel) per
/// screen, keyboard input goes to the *key* window — so the screen you're mousing
/// over should be the one listening, no click required. During calibration that
/// keys the cursor screen's panel (arrow-key tape nudges); in the arranger it keys
/// the cursor screen's canvas (Esc/⌘Z/arrows from wherever you're looking).
///
/// This class is the app's single owner of cursor-screen tracking for focus.
/// Calibration deliberately owns none (see `CalibrationController.focusPanel(on:)`,
/// which is safe to call liberally). Mechanism: a light poll of
/// `NSEvent.mouseLocation` doing screen-*change* detection only — no event monitors,
/// so no window anywhere needs `acceptsMouseMovedEvents` for this to work.
@MainActor
final class FocusPolicy {

    // Wired once by the AppDelegate.
    var isCalibrationActive: () -> Bool = { false }
    var focusCalibration: (NSScreen) -> Void = { _ in }
    var isArrangerVisible: () -> Bool = { false }
    var focusArranger: (NSScreen) -> Void = { _ in }

    private var timer: Timer?
    /// The cursor's screen at the last tick, by frame — NSScreen instances aren't
    /// stable across calls, so identity comparisons would retrigger endlessly.
    private var lastScreenFrame: NSRect?

    /// Start following (idempotent). Call whenever a followable surface appears
    /// (arranger shown, calibration begun); the timer retires itself when none is left.
    func begin() {
        guard timer == nil else { return }
        lastScreenFrame = nil   // re-key on the first tick even if the screen "didn't change"
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let calibrating = isCalibrationActive()
        guard calibrating || isArrangerVisible() else {
            timer?.invalidate(); timer = nil; lastScreenFrame = nil
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
}
