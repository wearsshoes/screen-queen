import SwiftUI

/// The schematic, hosted in a SwiftUI `Canvas`. The render pass
/// (`Stage.drawSchematic(in:size:)`) draws natively into the GraphicsContext.
///
/// Mouse input lives here too (phase 2 of the input port): one DragGesture drives the
/// stage's began/moved/ended handlers — a plain click is a zero-distance drag, same as
/// mouseDown/mouseUp. Gesture points pass straight through: the view is flipped, so
/// gesture, Stage, and view space are all the same y-down coordinates.
struct SchematicCanvasView: View {
    weak var stage: Stage?
    /// Bumped by `repaintSchematic()` — the Canvas closure re-runs when inputs change.
    var generation: Int

    var body: some View {
        Canvas { ctx, size in
            _ = generation
            stage?.drawSchematic(in: ctx, size: size)
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                guard let stage else { return }
                if stage.mouseGestureActive { stage.mouseMoved(to: g.location) }
                else { stage.mouseBegan(at: g.location, option: NSEvent.modifierFlags.contains(.option)) }
            }
            .onEnded { g in
                stage?.mouseEnded(at: g.location)
            })
    }
}

/// The schematic's hosting view. Left-button input goes to the SwiftUI gesture above;
/// right-click forwards to the stage's context-menu builder; first clicks land even
/// when the overlay window isn't key.
final class SchematicCanvasHost: NSHostingView<SchematicCanvasView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        rootView.stage?.menu(for: event)
    }
    /// Key this screen's arranger on click, before the gesture fires — the AppKit
    /// half of the click that the framework-free mouseBegan no longer does.
    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        if let stage = rootView.stage { window?.makeFirstResponder(stage) }
        super.mouseDown(with: event)
    }
}

// MARK: - The render pass

/// `drawSchematic(in:size:)` orchestrates the schematic in paint order. The subjects
/// live in their own files — the minimap (Minimap/Stage+Tiles, +TileSeams,
/// +TileMarkers) and the on-glass halves (Chrome/Glass/EdgeSeams, EdgeMarkers).
extension Stage {

    func drawSchematic(in ctx: GraphicsContext, size: CGSize) {
        // The backdrop wash. If this screen's own tile is being dragged (from any
        // stage), brighten it — a real-world "you're dragging me" cue.
        let beingDragged = centerID != nil && model.draggingDisplayID == centerID
        let wash: Color = beingDragged
            ? Color(nsColor: NSColor.systemPink.blended(withFraction: 0.2, of: .black) ?? .systemPink).opacity(0.75)
            : Color.black.opacity(0.55)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(wash))

        let rects = currentRects()
        guard let t = drawTransform(rects) else {
            ctx.draw(Text(Copy.emptyState).font(.system(size: 14))
                .foregroundStyle(.secondary),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let bars = model.currentBars()
        let seamColor = model.seamColors(bars)   // color per seam; both its bars share it
        if model.showAlignGhosts { minimap.drawAlignGhosts(ctx, t: t) }   // under the tiles
        // Selection halo before the tiles, so it reads under the lifted tile.
        if let sel = selectedID, let r = rects[sel] { minimap.drawSelectedShadow(ctx, t.viewRect(r)) }
        for d in displays where rects[d.id] != nil { minimap.drawTile(ctx, for: d, in: t.viewRect(rects[d.id]!)) }
        // Predicted Dock strip. With the live feed on the tiles already show the real
        // Dock, so only surface it when informative (Dock would move / mid menu-bar drag).
        if let dockID = model.predictedDockDisplay(), let r = rects[dockID] {
            let dockWouldMove = dockID != model.currentDockDisplay()
            let showDock = !model.feedEnabled || dockWouldMove || draggingMenuBar != nil
            if showDock {
                minimap.drawDockIndicator(ctx, in: t.viewRect(r), edge: DockPredictor.edge())
            }
        }
        // Seam glows, painted from the same edge sets `updateSeamEffects` feeds to the
        // emitter/glow layers (on the refresh path — draw registers nothing).
        for e in minimap.miniBarEdges(bars, t: t, seamColor: seamColor) { drawBehindGlow(ctx, e) }
        let markers = minimap.activeMarkers(rects)
        for d in displays where rects[d.id] != nil { minimap.drawAnchors(ctx, for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        for e in edgeBarEdges(bars, seamColor: seamColor) { drawBehindGlow(ctx, e) }
        drawScreenMarkers(ctx, markers)           // alignment notches/arrows at this screen's real edges
        if let p = draggingMenuBar {
            // The strip follows the cursor; highlight the tile it would land on.
            if let over = display(at: p), !over.isMain, let r = rects[over.id] {
                let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
                ctx.fill(Path(roundedRect: vr, cornerRadius: minimap.tileCornerRadius),
                         with: .color(.white.opacity(0.25)))
            }
            minimap.drawMenuBar(ctx, in: NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
        }
        // Option-mirror drag: highlight the tile the dragged display would mirror onto.
        if let p = mirrorDragPoint, let over = display(at: p), over.id != draggedID, let r = rects[over.id] {
            let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
            let pink = Color.pink
            let path = Path(roundedRect: vr, cornerRadius: minimap.tileCornerRadius)
            ctx.fill(path, with: .color(pink.opacity(0.35)))
            ctx.stroke(path, with: .color(pink), lineWidth: 2)
            ctx.draw(Text(Copy.mirrorDropHint).font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white),
                     at: CGPoint(x: vr.midX, y: vr.midY))
        }
    }
}
