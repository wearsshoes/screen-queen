import SwiftUI

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass
/// (`Arranger.drawSchematic(in:size:)`) draws natively into the GraphicsContext where
/// subjects have been migrated, and runs the rest through the `legacyDraw` y-up shim —
/// see Arranger+Drawing for the migration state.
///
/// Mouse input lives here too (phase 2 of the input port): one DragGesture drives the
/// canvas's began/moved/ended handlers — a plain click is a zero-distance drag, same as
/// mouseDown/mouseUp. Points are flipped to the y-up view space the handlers speak.
struct SchematicCanvasView: View {
    weak var canvas: Arranger?
    /// Bumped by `repaintSchematic()` — the Canvas closure re-runs when inputs change.
    var generation: Int

    var body: some View {
        Canvas { ctx, size in
            _ = generation
            canvas?.drawSchematic(in: ctx, size: size)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard let canvas else { return }
                let p = CGPoint(x: g.location.x, y: canvas.bounds.height - g.location.y)
                if canvas.mouseGestureActive { canvas.mouseMoved(to: p) }
                else { canvas.mouseBegan(at: p, option: NSEvent.modifierFlags.contains(.option)) }
            }
            .onEnded { g in
                guard let canvas else { return }
                canvas.mouseEnded(at: CGPoint(x: g.location.x,
                                              y: canvas.bounds.height - g.location.y))
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
