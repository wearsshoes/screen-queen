import SwiftUI

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass
/// (`Canvas.drawSchematic(in:size:)`) draws natively into the GraphicsContext.
///
/// Mouse input lives here too (phase 2 of the input port): one DragGesture drives the
/// canvas's began/moved/ended handlers — a plain click is a zero-distance drag, same as
/// mouseDown/mouseUp. Gesture points pass straight through: the view is flipped, so
/// gesture, Canvas, and view space are all the same y-down coordinates.
struct SchematicCanvasView: View {
    weak var canvas: Canvas?
    /// Bumped by `repaintSchematic()` — the Canvas closure re-runs when inputs change.
    var generation: Int

    var body: some View {
        SwiftUI.Canvas { ctx, size in
            _ = generation
            canvas?.drawSchematic(in: ctx, size: size)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard let canvas else { return }
                if canvas.mouseGestureActive { canvas.mouseMoved(to: g.location) }
                else { canvas.mouseBegan(at: g.location, option: NSEvent.modifierFlags.contains(.option)) }
            }
            .onEnded { g in
                canvas?.mouseEnded(at: g.location)
            })
    }
}

/// The schematic's hosting view. Left-button input goes to the SwiftUI gesture above;
/// right-click forwards to the canvas's context-menu builder; first clicks land even
/// when the overlay window isn't key.
final class SchematicCanvasHost: NSHostingView<SchematicCanvasView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        rootView.canvas?.menu(for: event)
    }
    /// Key this screen's arranger on click, before the gesture fires — the AppKit
    /// half of the click that the framework-free mouseBegan no longer does.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        if let canvas = rootView.canvas { window?.makeFirstResponder(canvas) }
        super.mouseDown(with: event)
    }
}
