import AppKit

/// Rendering: draws the schematic (tiles, labels, reference/edge bars, alignment
/// markers, boxing) from the shared `state` and the view transform.
extension Arranger {

    // MARK: - Drawing

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
        // Selection: a soft drop shadow behind the selected tile, drawn before the tiles
        // so the shadow reads under it (the tile lifts off the plane, macOS-style).
        if let sel = selectedID, let r = rects[sel] { drawSelectedShadow(t.viewRect(r)) }
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!), scale: t.scale) }
        // Hide info cards for displays not drawn this pass so a stale card doesn't linger.
        let drawn = Set(displays.filter { rects[$0.id] != nil }.map(\.id))
        for (id, card) in labelCards where !drawn.contains(id) { card.isHidden = true }
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
        updateSolvePanel(seamColor: seamColor)    // the "what she sees" panel (floats above)
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

    /// Reference bars at each seam: the reference window shown on each side at its own
    /// physical size (the size jump a window makes crossing the seam). D-shaped, flush
    /// to the seam, rounding toward the owning display's center.
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform, seamColor: [DisplayGraph.SeamKey: NSColor]) {
        let thickness: CGFloat = 5, gap: CGFloat = 2
        // Trim the ends clear of the rounded corners, capped at 1/3 so a short bar's
        // length stays proportional to the true overlap.
        func barLen(_ inches: CGFloat) -> CGFloat {
            let full = inches * t.scale
            return max(1.5, full - min(8, full / 3))
        }
        for bar in bars {
            let color = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let lenA = barLen(bar.physLenInchesA)
            let lenB = barLen(bar.physLenInchesB)
            if bar.isVertical {
                let cA = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongA))
                let cB = t.viewPoint(CGPoint(x: bar.physLine, y: bar.physAlongB))
                // a = left display: its bar hugs the seam and rounds toward its center.
                drawBar(NSRect(x: cA.x - gap - thickness, y: cA.y - lenA / 2, width: thickness, height: lenA), roundedOn: .minX, color: color)
                drawBar(NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB), roundedOn: .maxX, color: color)
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                // a = top display: its bar sits above the seam and rounds toward its center.
                drawBar(NSRect(x: cA.x - lenA / 2, y: cA.y + gap, width: lenA, height: thickness), roundedOn: .maxY, color: color)
                drawBar(NSRect(x: cB.x - lenB / 2, y: cB.y - gap - thickness, width: lenB, height: thickness), roundedOn: .minY, color: color)
            }
        }
    }

    /// This screen's density relative to the 109 pt/in panels the sparkle look was tuned
    /// on — keeps the shimmer the same *physical* size on every screen.
    private var screenDensityScale: CGFloat {
        let ppi = displays.first { $0.id == centerID }?.pointsPerInch
        return CGFloat(ppi ?? 109) / 109
    }

    /// A D-shaped mini-map bar: a wide soft glow behind the sparkles (painted here) and
    /// a tight bright glow in front (overlay layer). Sparkles drift inward and fade.
    private func drawBar(_ rect: NSRect, roundedOn inward: RectEdge, color: NSColor) {
        drawBehindGlow(rect, roundedOn: inward, color: color)
        let eid = barID(rect, inward)
        seamEmitters.add(edgeOf: rect, direction: particleDirection(inward), color: color,
                         id: "mini-\(eid)", sizeScale: screenDensityScale)
        seamGlow.add(rect: rect, inward: overlayEdge(inward), color: color, id: "mini-\(eid)")
    }

    /// The wide, soft glow behind the sparkles: opaque at the seam edge, fading to clear
    /// ~2× the bar depth into the tile, clipped to a D-shape extended to that reach.
    private func drawBehindGlow(_ rect: NSRect, roundedOn inward: RectEdge, color: NSColor) {
        let depth = (inward == .minX || inward == .maxX) ? rect.width : rect.height
        let reach = depth * behindGlowReach
        // Grow the rect inward so its inward edge lands at the glow's end.
        let ext: NSRect
        switch inward {
        case .minX: ext = NSRect(x: rect.maxX - reach, y: rect.minY, width: reach, height: rect.height)
        case .maxX: ext = NSRect(x: rect.minX, y: rect.minY, width: reach, height: rect.height)
        case .minY: ext = NSRect(x: rect.minX, y: rect.maxY - reach, width: rect.width, height: reach)
        case .maxY: ext = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: reach)
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        dPath(ext, roundedOn: inward).addClip()
        // Gradient from the seam edge → the extended inward edge: opaque → clear.
        let (start, end): (CGPoint, CGPoint)
        switch inward {
        case .minX: start = CGPoint(x: ext.maxX, y: ext.midY); end = CGPoint(x: ext.minX, y: ext.midY)
        case .maxX: start = CGPoint(x: ext.minX, y: ext.midY); end = CGPoint(x: ext.maxX, y: ext.midY)
        case .minY: start = CGPoint(x: ext.midX, y: ext.maxY); end = CGPoint(x: ext.midX, y: ext.minY)
        case .maxY: start = CGPoint(x: ext.midX, y: ext.minY); end = CGPoint(x: ext.midX, y: ext.maxY)
        }
        let gradient = NSGradient(colors: [color.withAlphaComponent(0.7), color.withAlphaComponent(0)],
                                  atLocations: [0, 1], colorSpace: .sRGB)
        // Own transparency layer, so the destination-out end feathers below erase only
        // the glow, not the canvas painted beneath it.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        gradient?.draw(from: start, to: end, options: [])
        let vertical = inward == .minX || inward == .maxX
        let alongLen = vertical ? ext.height : ext.width
        let ramp = min(22, alongLen * 0.3)
        if ramp > 1, let fade = NSGradient(colors: [.black, NSColor.black.withAlphaComponent(0)],
                                           atLocations: [0, 1], colorSpace: .sRGB) {
            ctx.setBlendMode(.destinationOut)
            if vertical {
                fade.draw(from: CGPoint(x: ext.midX, y: ext.minY), to: CGPoint(x: ext.midX, y: ext.minY + ramp), options: [])
                fade.draw(from: CGPoint(x: ext.midX, y: ext.maxY), to: CGPoint(x: ext.midX, y: ext.maxY - ramp), options: [])
            } else {
                fade.draw(from: CGPoint(x: ext.minX, y: ext.midY), to: CGPoint(x: ext.minX + ramp, y: ext.midY), options: [])
                fade.draw(from: CGPoint(x: ext.maxX, y: ext.midY), to: CGPoint(x: ext.maxX - ramp, y: ext.midY), options: [])
            }
            ctx.setBlendMode(.normal)
        }
        ctx.endTransparencyLayer()
    }

    /// The behind glow reaches this multiple of the bar depth toward the display center.
    private var behindGlowReach: CGFloat { 2 }

    /// Map a drawing `RectEdge` to the overlay glow's inward direction.
    private func overlayEdge(_ inward: RectEdge) -> SeamGlow.Edge {
        switch inward {
        case .minX: return .minX
        case .maxX: return .maxX
        case .minY: return .minY
        case .maxY: return .maxY
        }
    }

    /// The direction particles drift: toward the display center = the `inward` edge. View is
    /// y-up, so the `minY` edge faces the screen *bottom* (drift down) and `maxY` the top.
    private func particleDirection(_ inward: RectEdge) -> SeamEmitters.Direction {
        switch inward {
        case .minX: return .left
        case .maxX: return .right
        case .minY: return .down
        case .maxY: return .up
        }
    }

    /// A stable per-edge id (quantized so sub-pixel jitter doesn't reseed the emitter).
    private func barID(_ r: NSRect, _ inward: RectEdge) -> String {
        "\(Int(r.minX / 3))-\(Int(r.minY / 3))-\(inward)"
    }

    /// Full-screen reference bars hugging *this* screen's real edges, in the seam's
    /// color — the on-glass depiction of a window's size jump crossing the seam.
    private func drawEdgeBars(_ bars: [SeamBar], seamColor: [DisplayGraph.SeamKey: NSColor]) {
        guard let me = centerID else { return }
        // Constant *physical* thickness: convert inches → points via this screen's density.
        let thicknessInches: CGFloat = 0.08
        let ppi = displays.first { $0.id == me }?.pointsPerInch
        let thickness: CGFloat = ppi.map { thicknessInches * CGFloat($0) } ?? 9
        // Bar offsets/lengths are in *previewed* point space but drawn against the real
        // window bounds — scale them across, or spacing drifts during a zoom preview.
        let previewed = displays.first { $0.id == me }.map { pointSize($0) }
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            let axisPreview = bar.isVertical ? (previewed?.height ?? bounds.height)
                                             : (previewed?.width ?? bounds.width)
            let axisReal = bar.isVertical ? bounds.height : bounds.width
            let s = axisPreview > 0 ? axisReal / axisPreview : 1
            let along = (weAreA ? bar.localAlongA : bar.localAlongB) * s
            // End margin capped so a short crossing region shrinks proportionally.
            let len = max(1.5, bar.windowPoints * s - min(12, bar.windowPoints * s / 3))
            let rect: NSRect
            // `inward` = the side facing the screen center (rounded); outward sits flat.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                // `along` is y-down from the screen top; flip through the one point-space gate.
                let yCenter = pointYToView(along)
                rect = NSRect(x: x, y: yCenter - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX
            } else {
                let y = weAreA ? 0 : bounds.height - thickness   // a = above the seam
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .maxY : .minY
            }
            drawBehindGlow(rect, roundedOn: inward, color: facing)
            let eid = barID(rect, inward)
            // Full-screen scale → larger particles, deeper drift than the mini-map bars.
            seamEmitters.add(edgeOf: rect, direction: particleDirection(inward), color: facing,
                             id: "edge-\(eid)", sizeScale: 2 * screenDensityScale, travelBoost: 3)
            seamGlow.add(rect: rect, inward: overlayEdge(inward), color: facing, id: "edge-\(eid)")
        }
    }

    private enum RectEdge { case minX, maxX, minY, maxY }

    /// A rect with only the two corners on the `inward` edge rounded (radius 0 keeps the
    /// outward corners square).
    private func dPath(_ r: NSRect, roundedOn inward: RectEdge) -> NSBezierPath {
        let cr = min(r.width, r.height) * 0.45
        let bl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.maxY), tl = CGPoint(x: r.minX, y: r.maxY)
        func rad(_ c: RectEdge...) -> CGFloat { c.contains(inward) ? cr : 0 }
        let rBL = rad(.minX, .minY), rBR = rad(.maxX, .minY)
        let rTR = rad(.maxX, .maxY), rTL = rad(.minX, .maxY)

        let p = NSBezierPath()
        p.move(to: CGPoint(x: (bl.x + br.x) / 2, y: bl.y))     // start mid-bottom (away from a corner)
        p.appendArc(from: br, to: tr, radius: rBR)
        p.appendArc(from: tr, to: tl, radius: rTR)
        p.appendArc(from: tl, to: bl, radius: rTL)
        p.appendArc(from: bl, to: br, radius: rBL)
        p.close()
        return p
    }

    /// A pink glow halo behind the selected tile, drawn *before* it so only the blur
    /// bleeds out (seam glitter, drawn later, is untouched). Two passes: wide soft
    /// bloom, then a tight bright ring.
    private func drawSelectedShadow(_ tileRect: NSRect) {
        let path = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
                                xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        for (blur, alpha) in [(30.0, 0.55), (12.0, 0.95)] as [(CGFloat, CGFloat)] {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor.systemPink.withAlphaComponent(alpha)
            glow.shadowBlurRadius = blur
            glow.shadowOffset = .zero          // even glow, not a drop shadow
            glow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Depth a bottom Dock strip occupies within a tile (mirrors `drawDockIndicator`'s
    /// geometry), so other chrome can clear it.
    func dockStripDepth(in tile: NSRect) -> CGFloat {
        let inset = tile.insetBy(dx: 1.5, dy: 1.5)
        let icon = min(max(inset.height * 0.10, 7), 15)
        let tray = icon * 0.34
        let margin = icon * 0.5
        return margin + icon + tray * 2 + 4   // + a little breathing room
    }

    /// The macOS Dock in miniature (3 squircles · divider · Trash) hugging the predicted
    /// Dock edge of a tile.
    private func drawDockIndicator(in tile: NSRect, edge: DockPredictor.Edge) {
        let inset = tile.insetBy(dx: 1.5, dy: 1.5)
        let horizontal = (edge == .bottom)
        let icon = min(max((horizontal ? inset.height : inset.width) * 0.10, 7), 15)
        let gap = icon * 0.28
        let preDivider = icon * 0.22
        let postDivider = icon * 0.34
        let tray = icon * 0.34                          // dark tray padding around the icons
        let margin = icon * 0.5                         // clearance from the screen edge
        let r = icon * 0.28                             // squircle corner radius

        // Run length along the Dock axis: 3 icons (2 gaps) + pre + divider + post + 1 icon.
        let lineThick = max(1, icon * 0.12)
        let runLen = icon * 4 + gap * 2 + preDivider + lineThick + postDivider

        // Depth band (perpendicular to the Dock axis) shared by icons + tray.
        let depthLo: CGFloat   // near edge in view coords
        switch edge {
        case .bottom: depthLo = inset.minY + margin          // minY is the screen bottom
        case .left:   depthLo = inset.minX + margin
        case .right:  depthLo = inset.maxX - margin - icon
        }
        func square(at a: CGFloat) -> NSRect {
            horizontal ? NSRect(x: a, y: depthLo, width: icon, height: icon)
                       : NSRect(x: depthLo, y: a, width: icon, height: icon)
        }
        let startA = (horizontal ? inset.midX : inset.midY) - runLen / 2

        // Dark rounded tray behind everything, padded by `tray` on all sides.
        let trayRect: NSRect = horizontal
            ? NSRect(x: startA - tray, y: depthLo - tray, width: runLen + tray * 2, height: icon + tray * 2)
            : NSRect(x: depthLo - tray, y: startA - tray, width: icon + tray * 2, height: runLen + tray * 2)
        let trayR = (horizontal ? trayRect.height : trayRect.width) * 0.32
        NSColor(white: 0.32, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: trayRect, xRadius: trayR, yRadius: trayR).fill()

        func squircle(_ rect: NSRect) {
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        }

        var a = startA
        for i in 0..<3 { squircle(square(at: a)); a += icon + (i < 2 ? gap : preDivider) }  // 3 icons, tight then pre-divider gap
        // Divider line spanning the icon depth, across the Dock axis.
        let s = square(at: a)
        let line: NSRect = horizontal
            ? NSRect(x: a, y: s.minY + icon * 0.1, width: lineThick, height: icon * 0.8)
            : NSRect(x: s.minX + icon * 0.1, y: a, width: icon * 0.8, height: lineThick)
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: line, xRadius: line.width / 2, yRadius: line.height / 2).fill()
        a += lineThick + postDivider
        squircle(square(at: a))                                     // 4th icon (Trash)
    }

    private func drawTile(for display: DisplaySnapshot, in rect: NSRect, scale: CGFloat) {
        // Tiles stay neutral — color lives on the seams; selection gets the accent wash.
        let selected = display.id == selectedID
        let color = selected
            ? NSColor.systemPink.blended(withFraction: 0.75, of: .white) ?? .white
            : NSColor(white: 0.72, alpha: 0.85)
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        color.setFill(); path.fill()
        color.setStroke(); path.lineWidth = 1.5; path.stroke()
        drawWallpaper(for: display, in: inset, selected: selected)
        drawBoxing(for: display, in: inset, color: color)
        drawLabel(for: display, in: inset, selected: selected, viewScale: scale, tileColor: color)
        // The main display carries a menu-bar strip (drag it to another tile to move main).
        if display.isMain, draggingMenuBar == nil { drawMenuBar(in: menuBarRect(inTile: inset)) }
    }

    /// Fill the tile with what's on that screen: a live capture frame when the feed is
    /// on, else the static wallpaper. A mirrored slave shows its master's content.
    private func drawWallpaper(for display: DisplaySnapshot, in tile: NSRect, selected: Bool) {
        let sourceID = display.mirrorMaster ?? display.id
        let live = state.feedEnabled ? state.capture?.frames[sourceID] : nil
        let image = live ?? wallpaper(for: display)?.asCGImage
        guard let image else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: tile, xRadius: tileCornerRadius, yRadius: tileCornerRadius).addClip()
        drawImageAspectFill(image, in: tile, alpha: selected ? 1.0 : 0.95)

        // A faint scrim so seam bars/anchors keep contrast against busy content.
        NSColor.black.withAlphaComponent(selected ? 0.06 : 0.12).setFill()
        tile.fill()
    }

    /// Draw `image` aspect-filled (cover, center-crop) into `rect`.
    func drawImageAspectFill(_ image: CGImage, in rect: NSRect, alpha: CGFloat = 1) {
        guard let ctx = NSGraphicsContext.current?.cgContext, image.width > 0, image.height > 0 else { return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let w = iw * scale, h = ih * scale
        // Pixel-snap the destination: a sub-pixel origin softens the whole image, and the
        // cover-crop already bleeds past the tile so a ≤1px nudge is free.
        let dst = NSRect(x: pixelSnap(rect.midX - w / 2), y: pixelSnap(rect.midY - h / 2),
                         width: pixelSnap(w), height: pixelSnap(h))

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        ctx.draw(image, in: dst)
    }

    /// The desktop wallpaper for `display` (its master, if mirrored), cached and
    /// reloaded when the wallpaper URL changes.
    private func wallpaper(for display: DisplaySnapshot) -> NSImage? {
        let id = display.mirrorMaster ?? display.id
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }), let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallpaperCache[display.id] = .some(nil)
            return nil
        }
        if let cached = wallpaperCache[display.id], let entry = cached, entry.url == url {
            return entry.image
        }
        let image = NSImage(contentsOf: url)
        wallpaperCache[display.id] = image.map { (url, $0) }
        return image
    }

    /// When the (previewed) mode's aspect doesn't match the panel's, outline the actual
    /// image area and hatch the letter-/pillar-box bars.
    private func drawBoxing(for display: DisplaySnapshot, in tile: NSRect, color: NSColor) {
        let pending = state.pendingMode(for: display.id)
        let imgW = Double(pending?.pixelWidth ?? Int(display.pixelSize.width))
        let imgH = Double(pending?.pixelHeight ?? Int(display.pixelSize.height))
        guard imgW > 0, imgH > 0, let panAspect = nativeAspect(display.id) else { return }
        let imgAspect = imgW / imgH
        guard abs(imgAspect - panAspect) / panAspect > 0.02 else { return }   // fills the panel

        // The largest tile-centered rect with the image's aspect.
        var img = tile.insetBy(dx: 2, dy: 2)
        if imgAspect > panAspect {                 // wider than panel → letterbox
            let h = img.width / CGFloat(imgAspect)
            img = NSRect(x: img.minX, y: img.midY - h / 2, width: img.width, height: h)
        } else {                                   // narrower → pillarbox
            let w = img.height * CGFloat(imgAspect)
            img = NSRect(x: img.midX - w / 2, y: img.minY, width: w, height: img.height)
        }
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outline = NSBezierPath(rect: img); outline.lineWidth = 1; outline.stroke()
        hatch(tile.insetBy(dx: 2, dy: 2), excluding: img, color: NSColor.black.withAlphaComponent(0.3))
    }

    /// Native pixel aspect for `id`, cached in `nativeAspectCache`.
    func nativeAspect(_ id: CGDirectDisplayID) -> Double? {
        if let cached = nativeAspectCache[id] { return cached }
        let a = ModeCatalog.nativeAspect(for: id)
        nativeAspectCache[id] = a
        return a
    }

    /// Fill the region of `rect` outside `hole` with faint diagonal hatch lines.
    private func hatch(_ rect: NSRect, excluding hole: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: rect)
        clip.append(NSBezierPath(rect: hole).reversed)   // even-odd hole
        clip.addClip()
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY)); path.line(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += 6
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The menu-bar strip across the top of a tile.
    func menuBarRect(inTile tile: NSRect) -> NSRect {
        let h = min(18, tile.height * 0.2)
        return NSRect(x: tile.minX, y: tile.maxY - h, width: tile.width, height: h)
    }

    private func drawMenuBar(in rect: NSRect) {
        let clip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.white.withAlphaComponent(0.6).setFill(); clip.fill()
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect, selected: Bool, viewScale: CGFloat, tileColor: NSColor) {
        let sz = pointSize(display)
        let pending = state.pendingMode(for: display.id)
        let pixelW = pending?.pixelWidth ?? Int(display.pixelSize.width)

        // Effective PPI (points per physical inch, from the live/previewed point size).
        let effPPI = display.diagonalInches > 0 && sz.width > 0
            ? Double(sz.width) / (Double(display.physicalSizeMM.width) / 25.4) : nil

        // True-size preview: the faithful on-tile font scale is `viewScale / ppi`, so
        // sliding the resolution grows/shrinks the text just as macOS will. A constant
        // gain lifts it to legible without distorting the ratios between screens.
        let previewGain: CGFloat = 5.25
        let previewScale = effPPI.map { viewScale / CGFloat($0) * previewGain } ?? (rect.height / 100)
        let fontScale = max(0.525, previewScale)
        func f(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            let base = bold ? NSFont.boldSystemFont(ofSize: size * fontScale) : .systemFont(ofSize: size * fontScale)
            return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        }

        // Light-on-dark text; selected tiles lift it toward the accent.
        let accent = NSColor.systemPink
        let primary = selected ? (accent.blended(withFraction: 0.3, of: .white) ?? accent) : .white
        let secondary = selected ? (accent.blended(withFraction: 0.5, of: .white) ?? accent) : NSColor.white.withAlphaComponent(0.7)
        let tertiary = secondary.withAlphaComponent(0.72)

        // Drag name (hot-pink script), government name (fine print — work names go in
        // baby letters), resolution, diagonal·ppi.
        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.nickname, DragFont.script(size: (26 * fontScale).rounded()), .systemPink))
        lines.append((display.name, f(10), tertiary))
        let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
        lines.append(("\(Int(sz.width))×\(Int(sz.height))" + hidpi, f(13), primary))
        let diag = display.diagonalInches > 0 ? String(format: "%.0f″ · ", display.diagonalInches) : ""
        if let effPPI {
            lines.append((diag + String(format: "%.0f ppi", effPPI), f(13), secondary))
        } else {
            lines.append((diag + Copy.calibratePrompt, f(13), secondary))
        }

        // Only the lines that fit the tile width; the card sizes to the widest.
        let gap: CGFloat = 3
        let visible = lines.filter { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width <= rect.width - 8 }
        let sizes = visible.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]) }
        guard let widest = sizes.map(\.width).max() else {
            labelCards[display.id]?.isHidden = true
            return
        }
        let total = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, visible.count - 1))
        let padX: CGFloat = 11, padY: CGFloat = 6
        let boxW = min(widest + padX * 2, rect.width - 4)
        // Pixel-snap the card's frame — the text snap inside it is only meaningful if
        // the card's own origin sits on the grid.
        let box = NSRect(x: pixelSnap(rect.midX - boxW / 2), y: pixelSnap(rect.midY - total / 2 - padY),
                         width: pixelSnap(boxW), height: pixelSnap(total + padY * 2))

        let card = ensureLabelCard(for: display.id)
        card.frame = box
        card.isHidden = false
        card.update(LabelCard.Content(
            lines: visible.map { LabelCard.Line(text: $0.0, font: $0.1, color: $0.2) },
            selected: selected, gap: gap))
    }

    /// The frosted info card for `id`, created on demand and added above the drawn tiles.
    private func ensureLabelCard(for id: CGDirectDisplayID) -> LabelCard {
        if let c = labelCards[id] { return c }
        let c = LabelCard(frame: .zero)
        addSubview(c)
        labelCards[id] = c
        return c
    }

    /// The eight perimeter anchor positions (corners + edge midpoints).
    private enum AnchorPos: CaseIterable {
        case topLeft, topMid, topRight, leftMid, rightMid, bottomLeft, bottomMid, bottomRight
        func point(in r: NSRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .topMid: return CGPoint(x: r.midX, y: r.maxY)
            case .topRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .leftMid: return CGPoint(x: r.minX, y: r.midY)
            case .rightMid: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.minY)
            case .bottomMid: return CGPoint(x: r.midX, y: r.minY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
            }
        }
        // Unit vector from the anchor toward the tile center.
        var inward: CGVector {
            switch self {
            case .topLeft: return CGVector(dx: 1, dy: -1)
            case .topMid: return CGVector(dx: 0, dy: -1)
            case .topRight: return CGVector(dx: -1, dy: -1)
            case .leftMid: return CGVector(dx: 1, dy: 0)
            case .rightMid: return CGVector(dx: -1, dy: 0)
            case .bottomLeft: return CGVector(dx: 1, dy: 1)
            case .bottomMid: return CGVector(dx: 0, dy: 1)
            case .bottomRight: return CGVector(dx: -1, dy: 1)
            }
        }
    }

    /// Eight notch markers per tile; the two aligned anchors become arrows pointing
    /// at each other.
    private func drawAnchors(for display: DisplaySnapshot, in rect: NSRect, active: (pos: AnchorPos, dir: CGVector)?) {
        let tile = rect.insetBy(dx: 1.5, dy: 1.5), r = tileCornerRadius
        // Markers sit inside the reference bars / menu strip (corners move diagonally).
        let marginTile = tile.insetBy(dx: 24, dy: 24)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).setClip()
        for pos in AnchorPos.allCases where active?.pos != pos {
            drawNotch(at: pos.point(in: marginTile), dir: pos.inward)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let active { drawArrow(at: active.pos.point(in: marginTile), dir: active.dir) }
    }

    /// The active alignment marker for this screen, drawn large at its real edges (in
    /// its own point coords) — the on-glass counterpart of the mini-map notches.
    private func drawScreenMarkers(_ markers: [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)]) {
        guard let me = centerID, let active = markers[me] else { return }
        let notch = window?.screen?.safeAreaInsets.top ?? 0   // keep clear of the notch on top
        // The notch is at the top, so reserve its clearance by shrinking the height.
        let area = NSRect(x: bounds.minX + 40, y: bounds.minY + 40,
                          width: bounds.width - 80, height: bounds.height - 80 - notch)
        drawArrow(at: active.pos.point(in: area), dir: active.dir, scale: 3)
    }

    /// Grey ghosts of where each valid ⌘⇧ arrow would move the selected tile, with a
    /// direction arrow. Drawn under the real tiles. The arrow sits at the ghost's
    /// center, or the center of its overlap with the current tile, or (if that overlap
    /// is too small) just outside the current tile in the move direction.
    private func drawAlignGhosts(t: Transform) {
        guard let selID = selectedID, let cur = plane[selID] else { return }
        let curView = t.viewRect(cur)
        for (dir, rect) in alignGhosts() {
            let g = t.viewRect(rect)
            let box = g.insetBy(dx: 1.5, dy: 1.5)
            NSColor.gray.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
            path.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()   // lighter outline
            path.lineWidth = 1; path.stroke()

            // The overlap is covered by the current tile (drawn on top), so aim the
            // arrow at the ghost's *exposed* strip (ghost minus the current tile),
            // biased toward the ghost. If that strip is too thin, nudge just outside.
            let overlap = g.intersection(curView)
            let at: CGPoint
            if overlap.isNull || overlap.width <= 0 || overlap.height <= 0 {
                at = CGPoint(x: g.midX, y: g.midY)               // no overlap → ghost center
            } else {
                let exposedX = max(g.maxX - curView.maxX, 0) >= max(curView.minX - g.minX, 0)
                    ? (g.maxX + curView.maxX) / 2 : (g.minX + curView.minX) / 2
                let exposedY = max(g.maxY - curView.maxY, 0) >= max(curView.minY - g.minY, 0)
                    ? (g.maxY + curView.maxY) / 2 : (g.minY + curView.minY) / 2
                // Move along whichever axis the ghost is actually offset.
                if abs(g.midX - curView.midX) >= abs(g.midY - curView.midY) {
                    at = CGPoint(x: exposedX, y: g.midY)
                } else {
                    at = CGPoint(x: g.midX, y: exposedY)
                }
            }
            let travel: CGVector
            switch dir {
            case .left:  travel = CGVector(dx: -1, dy: 0)
            case .right: travel = CGVector(dx: 1, dy: 0)
            case .up:    travel = CGVector(dx: 0, dy: 1)
            case .down:  travel = CGVector(dx: 0, dy: -1)
            }
            drawDirectionArrow(centeredAt: at, pointing: travel, length: 34)
        }
    }

    /// A clean "→"-style arrow (line shaft + open chevron head) pointing along `dir`,
    /// centered at `p`.
    private func drawDirectionArrow(centeredAt p: CGPoint, pointing dir: CGVector, length: CGFloat) {
        let n = unit(dir)
        let tail = CGPoint(x: p.x - n.dx * length / 2, y: p.y - n.dy * length / 2)
        let tip  = CGPoint(x: p.x + n.dx * length / 2, y: p.y + n.dy * length / 2)
        let perp = CGVector(dx: -n.dy, dy: n.dx)
        let head: CGFloat = 9
        let path = NSBezierPath()
        path.move(to: tail); path.line(to: tip)                                  // shaft
        path.move(to: CGPoint(x: tip.x - n.dx * head + perp.dx * head, y: tip.y - n.dy * head + perp.dy * head))
        path.line(to: tip)                                                       // chevron
        path.line(to: CGPoint(x: tip.x - n.dx * head - perp.dx * head, y: tip.y - n.dy * head - perp.dy * head))
        path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        NSColor.white.setStroke(); path.stroke()
    }

    /// Markers for the active alignment, read from the stored anchor pair; the
    /// facing side comes from the rendered rects.
    private func activeMarkers(_ rects: [CGDirectDisplayID: CGRect]) -> [CGDirectDisplayID: (pos: AnchorPos, dir: CGVector)] {
        guard let selID = selectedID, let sR = rects[selID] else { return [:] }
        if let a = activeV, let oR = rects[a.otherID] {
            let selLeft = sR.midX < oR.midX
            let sp = vPos(facingRight: selLeft, level: a.selfA), op = vPos(facingRight: !selLeft, level: a.otherA)
            return [selID: (sp, dirV(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirV(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        if let a = activeH, let oR = rects[a.otherID] {
            let selAbove = sR.midY < oR.midY
            let sp = hPos(facingBelow: selAbove, level: a.selfA), op = hPos(facingBelow: !selAbove, level: a.otherA)
            return [selID: (sp, dirH(sp, corner: a.selfA != .center, partner: a.otherA)),
                    a.otherID: (op, dirH(op, corner: a.otherA != .center, partner: a.selfA))]
        }
        return [:]
    }

    private func vPos(facingRight: Bool, level: VAnchor) -> AnchorPos {
        switch (facingRight, level) {
        case (true, .top): return .topRight
        case (true, .center): return .rightMid
        case (true, .bottom): return .bottomRight
        case (false, .top): return .topLeft
        case (false, .center): return .leftMid
        case (false, .bottom): return .bottomLeft
        }
    }
    private func hPos(facingBelow: Bool, level: HAnchor) -> AnchorPos {
        switch (facingBelow, level) {
        case (true, .left): return .bottomLeft
        case (true, .center): return .bottomMid
        case (true, .right): return .bottomRight
        case (false, .left): return .topLeft
        case (false, .center): return .topMid
        case (false, .right): return .topRight
        }
    }
    private func dirV(_ pos: AnchorPos, corner: Bool, partner: VAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: pos.inward.dx, dy: partner == .top ? 1 : -1)
    }
    private func dirH(_ pos: AnchorPos, corner: Bool, partner: HAnchor) -> CGVector {
        if corner { return pos.inward }
        guard partner != .center else { return pos.inward }
        return CGVector(dx: partner == .left ? -1 : 1, dy: pos.inward.dy)
    }

    private func drawNotch(at p: CGPoint, dir: CGVector) {
        let n = unit(dir), len: CGFloat = 4
        let path = NSBezierPath()
        path.move(to: p); path.line(to: CGPoint(x: p.x + n.dx * len, y: p.y + n.dy * len))
        path.lineWidth = 2; path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
    }

    private func drawArrow(at p: CGPoint, dir: CGVector, scale: CGFloat = 1) {
        let inward = unit(dir), out = CGVector(dx: -inward.dx, dy: -inward.dy)
        let len: CGFloat = 7 * scale, half: CGFloat = 4 * scale
        let perp = CGVector(dx: -out.dy, dy: out.dx)
        let apex = CGPoint(x: p.x + out.dx * len, y: p.y + out.dy * len)
        let b1 = CGPoint(x: p.x + perp.dx * half, y: p.y + perp.dy * half)
        let b2 = CGPoint(x: p.x - perp.dx * half, y: p.y - perp.dy * half)
        let tri = NSBezierPath(); tri.move(to: apex); tri.line(to: b1); tri.line(to: b2); tri.close()
        NSColor.white.setFill(); tri.fill()
    }

    private func unit(_ v: CGVector) -> CGVector {
        let len = max(hypot(v.dx, v.dy), 0.001)
        return CGVector(dx: v.dx / len, dy: v.dy / len)
    }

    /// Feed the "what she sees" panel the *actual* origins the seam detection uses (the
    /// locked solve during a drag), so the panel shows the truth.
    private func updateSolvePanel(seamColor: [DisplayGraph.SeamKey: NSColor]) {
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
