import AppKit

/// The topmost layer while the arranger is open: one small ✕ window in the
/// upper-right corner of every screen, above both the glass (dim + bars) and the
/// arranger (schematic). Clicking any of them dismisses.
@MainActor
final class CloseButtonController {

    var onClose: (() -> Void)?
    private var windows: [NSWindow] = []

    func show() {
        hide()
        let side = 2 * (CloseButton.margin + CloseButton.radius)
        for screen in NSScreen.screens {
            let f = screen.frame
            // Top-right corner of this screen, in global (y-up) coordinates.
            let rect = NSRect(x: f.maxX - side, y: f.maxY - side, width: side, height: side)

            let window = KeyableBorderlessWindow(contentRect: rect, styleMask: .borderless,
                                                 backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // Above the arranger and the menu bar (the ✕ sits in the top corner).
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isReleasedWhenClosed = false

            let view = CloseButtonView(frame: CGRect(origin: .zero, size: rect.size))
            view.onClose = { [weak self] in self?.onClose?() }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

/// A single ✕ button filling its (corner-sized) window.
private final class CloseButtonView: NSView {
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) { CloseButton.draw(in: bounds) }

    override func mouseDown(with event: NSEvent) {
        if CloseButton.hit(convert(event.locationInWindow, from: nil), in: bounds) { onClose?() }
    }
}
