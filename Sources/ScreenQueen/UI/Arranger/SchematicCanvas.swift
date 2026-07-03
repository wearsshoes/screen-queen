import SwiftUI

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass itself is still the
/// CoreGraphics code (`Arranger.drawSchematic`), run through `withCGContext` with a
/// y-flip so the AppKit-era drawing keeps its y-up view space — the mechanical first
/// step of the Canvas port; subjects can go native `GraphicsContext` incrementally.
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
            guard let canvas else { return }
            ctx.withCGContext { cg in
                // Canvas is y-down top-left; the draw code is y-up. Flip once here.
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                let ns = NSGraphicsContext(cgContext: cg, flipped: false)
                let prev = NSGraphicsContext.current
                NSGraphicsContext.current = ns
                canvas.drawSchematic()
                NSGraphicsContext.current = prev
            }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard let canvas else { return }
                let p = CGPoint(x: g.location.x, y: canvas.bounds.height - g.location.y)
                if canvas.mouseGestureActive { canvas.mouseMoved(to: p) }
                else { canvas.mouseBegan(at: p) }
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
}
