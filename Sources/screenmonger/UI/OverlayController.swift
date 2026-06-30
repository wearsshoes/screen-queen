import AppKit

/// Manages the transparent, click-through overlay window on each display that
/// renders the reference bars. Windows are created lazily and torn down (or
/// faded out) when the overlays are hidden or a display disconnects.
@MainActor
final class OverlayController {

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private(set) var isVisible = false
    private var fadeToken = 0

    func toggle(with displays: [DisplaySnapshot]) {
        if isVisible { hide() } else { show(with: displays) }
    }

    func show(with displays: [DisplaySnapshot]) {
        isVisible = true
        fadeToken &+= 1 // cancel any in-flight fade
        for window in windows.values { window.alphaValue = 1 }
        update(with: displays)
    }

    func hide() {
        isVisible = false
        fadeToken &+= 1
        for window in windows.values { window.orderOut(nil) }
        windows.removeAll()
    }

    /// Fade the bars out with an ease-in-out (S-curve) over `duration` seconds,
    /// e.g. after the user releases the manipulation keys.
    func fadeOut(duration: TimeInterval = 2) {
        guard isVisible else { return }
        isVisible = false
        fadeToken &+= 1
        let token = fadeToken
        let wins = Array(windows.values)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wins.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeToken == token else { return } // re-shown mid-fade
                for w in wins { w.orderOut(nil); w.alphaValue = 1 }
                self.windows.removeAll()
            }
        })
    }

    /// Rebuild overlay content. `displays` may be a prospective layout (drag /
    /// nudge / align / zoom preview); the bars are derived from it via the shared
    /// `SchematicLayout`, so the glass matches the arranger. No-op while hidden.
    func update(with displays: [DisplaySnapshot]) {
        guard isVisible else { return }

        let bars = SchematicLayout(displays: displays).bars
        let colors = DisplayGraph.colors(displays)
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let screens = screenMap()

        // The bar is the window's point size (from the layout). During a zoom
        // preview the real screen is still at its current resolution, so each
        // display's bar is scaled by realWidth/prospectiveWidth to render the
        // prospective size at the real pixel density.
        let real = DisplayManager.snapshot()
        let realWidths = Dictionary(uniqueKeysWithValues: real.map { ($0.id, $0.bounds.width) })

        var live: Set<CGDirectDisplayID> = []
        for d in displays {
            guard let screen = screens[d.id] else { continue }
            live.insert(d.id)

            let window = windows[d.id] ?? makeWindow()
            windows[d.id] = window
            window.setFrame(screen.frame, display: false)
            window.alphaValue = 1

            if let view = window.contentView as? OverlayView {
                view.frame = CGRect(origin: .zero, size: screen.frame.size)
                view.configure(me: d, byID: byID, bars: bars, colors: colors,
                               realWidths: realWidths)
            }
            window.orderFrontRegardless()
        }

        for (id, window) in windows where !live.contains(id) {
            window.orderOut(nil)
            windows[id] = nil
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let view = OverlayView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return window
    }

    private func screenMap() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber {
                result[number.uint32Value] = screen
            }
        }
        return result
    }
}
