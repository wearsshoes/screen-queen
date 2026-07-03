import AppKit

/// Borderless windows can't become key by default, which would block keyboard
/// input and buttons on the overlays. This subclass allows it.
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One full-screen overlay window per display, managed as a unit — the shared
/// shell for every production that covers the whole desk at once (the arranger;
/// the calibration session). Owns the lifecycle lessons every fleet otherwise
/// re-learns alone: recreate rather than reposition across a reconfig, borderless
/// keyability, Spaces behavior, don't-steal focus-follows-cursor.
@MainActor
final class Ensemble {

    private(set) var windows: [CGDirectDisplayID: NSWindow] = [:]
    var isVisible: Bool { !windows.isEmpty }

    private let level: NSWindow.Level
    private let backgroundColor: NSColor
    private let collectionBehavior: NSWindow.CollectionBehavior

    /// Dress a fresh member: install the content view, first responder, and any
    /// per-screen bookkeeping. Called once per created window, frame already set.
    var dress: (CGDirectDisplayID, NSWindow) -> Void = { _, _ in }
    /// A member left the cast (screen unplugged, or recreated after a frame
    /// change) — undo whatever `dress` built for that screen.
    var retire: (CGDirectDisplayID) -> Void = { _ in }

    /// Which screens get a member. Default: the whole desk; calibration casts
    /// only the two screens in the scene.
    var includes: (CGDirectDisplayID) -> Bool = { _ in true }

    init(level: NSWindow.Level, backgroundColor: NSColor = .clear,
         collectionBehavior: NSWindow.CollectionBehavior) {
        self.level = level
        self.backgroundColor = backgroundColor
        self.collectionBehavior = collectionBehavior
    }

    /// Diff the cast against the live screens: create members for new screens,
    /// recreate any whose screen frame changed (a borderless overlay doesn't
    /// reliably land when `setFrame`-d across a reconfig), retire the departed.
    func rebuild() {
        let screens = GlobalMap.screenMap()
        var live: Set<CGDirectDisplayID> = []
        for (id, screen) in screens where includes(id) {
            live.insert(id)
            if let existing = windows[id], existing.frame != screen.frame {
                existing.orderOut(nil)
                windows[id] = nil
                retire(id)
            }
            let window = windows[id] ?? makeWindow(id: id, frame: screen.frame)
            windows[id] = window
            window.orderFrontRegardless()
        }
        for (id, window) in windows where !live.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
            retire(id)
        }
    }

    /// Strike the set.
    func dismiss() {
        for (id, window) in windows {
            window.orderOut(nil)
            retire(id)
        }
        windows.removeAll()
    }

    /// Key the member on `screen` (focus-follows-cursor). No-op when that member
    /// is already key (don't-steal semantics).
    func focusWindow(on screen: NSScreen) {
        guard isVisible else { return }
        let window = windows.values.first { $0.screen?.frame == screen.frame }
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
    }

    private func makeWindow(id: CGDirectDisplayID, frame: NSRect) -> NSWindow {
        let window = KeyableBorderlessWindow(contentRect: frame, styleMask: .borderless,
                                             backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = backgroundColor
        window.hasShadow = false
        window.level = level
        window.collectionBehavior = collectionBehavior
        window.isReleasedWhenClosed = false
        dress(id, window)
        return window
    }
}
