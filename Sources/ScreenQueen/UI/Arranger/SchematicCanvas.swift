import SwiftUI

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass itself is still the
/// CoreGraphics code (`Arranger.drawSchematic`), run through `withCGContext` with a
/// y-flip so the AppKit-era drawing keeps its y-up view space — the mechanical first
/// step of the Canvas port; subjects can go native `GraphicsContext` incrementally.
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
    }
}

/// The schematic's hosting view: pure rendering — clicks fall through to the Arranger,
/// which keeps all input handling.
final class SchematicCanvasHost: NSHostingView<SchematicCanvasView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
