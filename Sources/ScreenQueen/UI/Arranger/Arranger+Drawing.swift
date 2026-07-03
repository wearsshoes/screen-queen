import AppKit

/// The render pass: `draw(_:)` orchestrates the schematic in paint order. The subjects
/// live in their own files — seams (Arranger+Seams), tiles (Arranger+Tiles), alignment
/// markers (Arranger+Markers), mirror column (Arranger+Sidebar).
extension Arranger {

    override func draw(_ dirtyRect: NSRect) {
        // The backdrop wash. If this screen's own tile is being dragged (from any
        // canvas), brighten it — a real-world "you're dragging me" cue.
        let beingDragged = centerID != nil && state.draggingDisplayID == centerID
        if beingDragged {
            (NSColor.systemPink.blended(withFraction: 0.2, of: .black) ?? .systemPink)
                .withAlphaComponent(0.75).setFill()
        } else {
            NSColor.black.withAlphaComponent(0.55).setFill()
        }
        bounds.fill()

        let rects = currentRects()
        guard let t = drawTransform(rects) else {
            drawCenteredMessage(Copy.emptyState)
            return
        }
        let bars = currentBars()
        let seamColor = seamColors(bars)   // color per seam; both its bars share it
        if showAlignGhosts { drawAlignGhosts(t: t) }   // under the tiles
        // Selection halo before the tiles, so it reads under the lifted tile.
        if let sel = selectedID, let r = rects[sel] { drawSelectedShadow(t.viewRect(r)) }
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!)) }
        // Predicted Dock strip. With the live feed on the tiles already show the real
        // Dock, so only surface it when informative (Dock would move / mid menu-bar drag).
        if let dockID = predictedDockDisplay(), let r = rects[dockID] {
            let dockWouldMove = dockID != state.currentDockDisplay()
            let showDock = !state.feedEnabled || dockWouldMove || draggingMenuBar != nil
            if showDock {
                drawDockIndicator(in: t.viewRect(r), edge: DockPredictor.edge())
            }
        }
        // The bar passes register the current seam edges with both layer overlays.
        seamEmitters.begin()
        seamGlow.begin()
        drawReferenceBars(bars, t: t, seamColor: seamColor)
        let markers = activeMarkers(rects)
        for d in displays where rects[d.id] != nil { drawAnchors(for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        drawEdgeBars(bars, seamColor: seamColor)   // full-screen reference bars hugging this screen's real edges
        seamEmitters.commit()
        seamGlow.commit()
        drawScreenMarkers(markers)                // alignment notches/arrows at this screen's real edges
        drawMirrorColumn()                        // mirrored displays live in the right column
        if let p = draggingMenuBar {
            // The strip follows the cursor; highlight the tile it would land on.
            if let over = display(at: p), !over.isMain, let r = rects[over.id] {
                let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
                NSColor.white.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: vr, xRadius: tileCornerRadius, yRadius: tileCornerRadius).fill()
            }
            drawMenuBar(in: NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
        }
        // Option-mirror drag: highlight the tile the dragged display would mirror onto.
        if let p = mirrorDragPoint, let over = display(at: p), over.id != draggedID, let r = rects[over.id] {
            let vr = t.viewRect(r).insetBy(dx: 1.5, dy: 1.5)
            NSColor.systemPink.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: vr, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
            path.fill()
            NSColor.systemPink.setStroke(); path.lineWidth = 2; path.stroke()
            let hint = Copy.mirrorDropHint
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
            let hs = (hint as NSString).size(withAttributes: a)
            (hint as NSString).draw(at: CGPoint(x: vr.midX - hs.width / 2, y: vr.midY - hs.height / 2), withAttributes: a)
        }
    }

    /// Feed the "what she sees" panel the *actual* origins the seam detection uses (the
    /// locked solve during a drag), so the panel shows the truth. Subview work — called
    /// from the refresh path, not from `draw(_:)`.
    func updateSolvePanel() {
        let seamColor = seamColors(currentBars())
        let origins = state.pointOrigins()
        let trace = SchematicLayout.solveTrace(rects: state.plane, displays: state.sizedDisplays())
        let ambiguousIDs = Set(trace.pointRects.filter(\.ambiguous).map(\.id))
        var content = SolvePanel.Content()
        for d in state.sizedDisplays() {
            guard let o = origins[d.id] else { continue }
            content.rects.append((d.id, CGRect(origin: o, size: d.bounds.size), ambiguousIDs.contains(d.id)))
        }
        for i in 0..<content.rects.count {
            for j in (i + 1)..<content.rects.count {
                guard let s = SchematicLayout.seam(content.rects[i].rect, content.rects[j].rect) else { continue }
                let key = DisplayGraph.SeamKey(content.rects[i].id, content.rects[j].id)
                content.seams.append((content.rects[i].id, content.rects[j].id, s.vertical,
                                      seamColor[key] ?? .systemPink))
            }
        }
        solvePanel.update(content)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
