import AppKit

/// Rendering: draws the schematic (tiles, labels, reference/edge bars, alignment
/// markers, boxing) from the shared `state` and the view transform.
extension Arranger {

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Each per-screen window owns its own dim backdrop. While another screen's tile
        // is being dragged, *this* screen brightens if it's the one being moved — a
        // real-world "you're dragging me" cue on the physical monitor: a brighter *and*
        // more opaque wash than the usual translucent dim.
        let beingDragged = centerID != nil && state.draggingDisplayID == centerID
        if beingDragged {
            // Wash the whole screen in the system accent (darkened a touch so tiles/bars
            // still read on top) — the same accent used for the selected tile.
            (NSColor.controlAccentColor.blended(withFraction: 0.35, of: .black) ?? .controlAccentColor)
                .withAlphaComponent(0.75).setFill()
        } else {
            // A behind-window blur sits under this wash; keep it fairly dark for a moody,
            // focused backdrop.
            NSColor.black.withAlphaComponent(0.55).setFill()
        }
        bounds.fill()

        let rects = currentRects()
        guard let t = dragTransform ?? transform(rects) else {
            drawCenteredMessage("No displays detected")
            return
        }
        let bars = currentBars()
        let seamColor = seamColors(bars)   // color per seam; both its bars share it
        if showAlignGhosts { drawAlignGhosts(t: t) }   // under the tiles
        // Selection: a soft drop shadow behind the selected tile, drawn before the tiles
        // so the shadow reads under it (the tile lifts off the plane, macOS-style).
        if let sel = selectedID, let r = rects[sel] { drawSelectedShadow(t.viewRect(r)) }
        for d in displays where rects[d.id] != nil { drawTile(for: d, in: t.viewRect(rects[d.id]!), scale: t.scale) }
        // Predicted Dock: a strip hugging the Dock edge of the screen it'll land on.
        // With the live feed on, the tiles already show the real desktop (Dock included),
        // so only surface the indicator when it's informative: the Dock would move, or a
        // menu-bar drag is underway (grabbing it signals intent to move main, so show it
        // immediately). With the feed off, always show it.
        if let dockID = predictedDockDisplay(), let r = rects[dockID] {
            let dockWouldMove = dockID != state.currentDockDisplay()
            let showDock = !state.feedEnabled || dockWouldMove || draggingMenuBar != nil
            if showDock {
                drawDockIndicator(in: t.viewRect(r), edge: DockPredictor.edge())
            }
        }
        // Seam particle emitters are repositioned each draw (they animate on the GPU
        // between draws). Wrap the bar passes, which register the current edges.
        seamEmitters.begin()
        drawReferenceBars(bars, t: t, seamColor: seamColor)
        let markers = activeMarkers(rects)
        for d in displays where rects[d.id] != nil { drawAnchors(for: d, in: t.viewRect(rects[d.id]!), active: markers[d.id]) }
        drawEdgeBars(bars, seamColor: seamColor)   // full-screen reference bars hugging this screen's real edges
        seamEmitters.commit()
        drawScreenMarkers(markers)                // alignment notches/arrows at this screen's real edges
        drawMirrorColumn()                        // mirrored displays live in the right column
        drawFooter("Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution")
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
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: vr, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
            path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
            let hint = "Mirror here"
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
            let hs = (hint as NSString).size(withAttributes: a)
            (hint as NSString).draw(at: CGPoint(x: vr.midX - hs.width / 2, y: vr.midY - hs.height / 2), withAttributes: a)
        }
    }

    /// Reference bars at each seam, in the seam's color: the reference window shown on
    /// each side at its own physical size (which differs by density — the size jump a
    /// window makes crossing the seam). Drawn D-shaped and flush to the seam line,
    /// echoing the on-glass edge bars: each bar rounds on the side facing its own
    /// display's center and sits flat against the seam.
    private func drawReferenceBars(_ bars: [SeamBar], t: Transform, seamColor: [DisplayGraph.SeamKey: NSColor]) {
        let thickness: CGFloat = 5, gap: CGFloat = 2   // hug the seam, small breathing gap
        // Ends clear the tile's rounded corners, but a fixed trim would swamp a short
        // bar and floor it to a constant stub — so cap the trim at 1/3 of the bar and
        // keep only a hairline floor, so length stays proportional to the true overlap.
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
                // a = left display: bar's right edge at the seam, rounds toward a's center (left).
                drawBar(NSRect(x: cA.x - gap - thickness, y: cA.y - lenA / 2, width: thickness, height: lenA), roundedOn: .minX, color: color)
                drawBar(NSRect(x: cB.x + gap, y: cB.y - lenB / 2, width: thickness, height: lenB), roundedOn: .maxX, color: color)
            } else {
                let cA = t.viewPoint(CGPoint(x: bar.physAlongA, y: bar.physLine))
                let cB = t.viewPoint(CGPoint(x: bar.physAlongB, y: bar.physLine))
                // a = top display (center above the seam, i.e. larger y): its bar sits above
                // the seam line and rounds on its top edge (.maxY, facing a's center); b
                // (below) sits under the seam and rounds .minY.
                drawBar(NSRect(x: cA.x - lenA / 2, y: cA.y + gap, width: lenA, height: thickness), roundedOn: .maxY, color: color)
                drawBar(NSRect(x: cB.x - lenB / 2, y: cB.y - gap - thickness, width: lenB, height: thickness), roundedOn: .minY, color: color)
            }
        }
    }

    /// A D-shaped mini-map bar: rounded on the `inward` edge (facing its display's
    /// center), flat against the seam. Colored circles drift off the inward edge toward
    /// the display center and fade out.
    private func drawBar(_ rect: NSRect, roundedOn inward: RectEdge, color: NSColor) {
        color.setFill()
        dPath(rect, roundedOn: inward).fill()
        // seamEmitters.add(edgeOf: rect, direction: particleDirection(inward), color: color,
        //                  id: "mini-\(barID(rect, inward))", sizeScale: 1)
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

    /// A stable per-edge id so an emitter persists across frames (quantized so sub-pixel
    /// jitter doesn't reseed a new emitter each draw).
    private func barID(_ r: NSRect, _ inward: RectEdge) -> String {
        "\(Int(r.minX / 3))-\(Int(r.minY / 3))-\(inward)"
    }

    /// Full-screen reference bars hugging *this* screen's real edges (in its own
    /// point coordinates), in the seam's color — the on-glass depiction of how big a
    /// window is as it crosses the seam. Drawn only on the window that sits on the
    /// participating screen; the matching bar on the other screen shares the color.
    private func drawEdgeBars(_ bars: [SeamBar], seamColor: [DisplayGraph.SeamKey: NSColor]) {
        guard let me = centerID else { return }
        // Constant *physical* thickness on every screen: these bars live in this screen's
        // point space, so a fixed point thickness would look thinner on a denser panel.
        // Convert a target physical thickness to points via this screen's density.
        let thicknessInches: CGFloat = 0.08
        let ppi = displays.first { $0.id == me }?.pointsPerInch
        let thickness: CGFloat = ppi.map { thicknessInches * CGFloat($0) } ?? 9
        // The bars' `localAlong`/`windowPoints` are in the display's *previewed* point
        // space (from `sizedDisplays`), but these edge bars are drawn against the real
        // window `bounds`. During a resolution preview those differ, so scale the along-
        // axis position/length from previewed points onto the real bounds — otherwise the
        // edge-bar spacing drifts while the zoom slider moves (the mini-map bars, which
        // live in previewed space throughout, stay correct).
        let previewed = displays.first { $0.id == me }.map { pointSize($0) }
        for bar in bars where bar.aID == me || bar.bID == me {
            let weAreA = (bar.aID == me)
            let facing = seamColor[DisplayGraph.SeamKey(bar.aID, bar.bID)] ?? .systemGray
            // Map previewed-point offsets onto the real window bounds along the seam axis.
            let axisPreview = bar.isVertical ? (previewed?.height ?? bounds.height)
                                             : (previewed?.width ?? bounds.width)
            let axisReal = bar.isVertical ? bounds.height : bounds.width
            let s = axisPreview > 0 ? axisReal / axisPreview : 1
            let along = (weAreA ? bar.localAlongA : bar.localAlongB) * s
            // Small end margin, but capped so a short crossing region shrinks
            // proportionally instead of vanishing into the fixed margin.
            let len = max(1.5, bar.windowPoints * s - min(12, bar.windowPoints * s / 3))
            let rect: NSRect
            // `inward` is the side facing the screen center (rounded); the opposite,
            // outward side sits flat against the screen edge.
            let inward: RectEdge
            if bar.isVertical {
                let x = weAreA ? bounds.width - thickness : 0    // a = left display
                rect = NSRect(x: x, y: along - len / 2, width: thickness, height: len)
                inward = weAreA ? .minX : .maxX                  // a hugs the right edge → rounds left
            } else {
                // `a` is above the seam, so the seam is at its bottom edge (y 0); "inward"
                // (toward center) rounds upward = .maxY.
                let y = weAreA ? 0 : bounds.height - thickness
                rect = NSRect(x: along - len / 2, y: y, width: len, height: thickness)
                inward = weAreA ? .maxY : .minY
            }
            facing.setFill()
            dPath(rect, roundedOn: inward).fill()
            // Edge bars are full-screen scale → larger particles than the mini-map bars.
            // seamEmitters.add(edgeOf: rect, direction: particleDirection(inward), color: facing,
            //                  id: "edge-\(barID(rect, inward))", sizeScale: 2.6)
        }
    }

    private enum RectEdge { case minX, maxX, minY, maxY }

    /// A rounded rect with only the two corners on the `inward` edge rounded (the
    /// outward edge and its corners stay square). `appendArc(from:to:radius:)` rounds
    /// each traversed corner; feeding radius 0 at the outward corners keeps them flat.
    private func dPath(_ r: NSRect, roundedOn inward: RectEdge) -> NSBezierPath {
        let cr = min(r.width, r.height) * 0.45   // corner radius on the inward side
        // Corners in order (bl, br, tr, tl) with the radius to use at each.
        let bl = CGPoint(x: r.minX, y: r.minY), br = CGPoint(x: r.maxX, y: r.minY)
        let tr = CGPoint(x: r.maxX, y: r.maxY), tl = CGPoint(x: r.minX, y: r.maxY)
        func rad(_ c: RectEdge...) -> CGFloat { c.contains(inward) ? cr : 0 }
        // Radius per corner: a corner is rounded iff it lies on the inward edge.
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

    /// A soft drop shadow behind the selected tile, lifting it off the plane. Drawn
    /// before the tile so the tile covers the fill and only the offset blur shows.
    private func drawSelectedShadow(_ tileRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)   // -y casts the shadow downward
        shadow.set()
        let path = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
                                xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A mini Dock hugging the predicted Dock edge of a tile: three app squircles, a
    /// divider line, and a fourth squircle (Trash) — the macOS Dock in miniature, so
    /// it's clear which screen the Dock lands on. Laid out along the Dock's axis.
    /// Depth (perpendicular to the Dock axis) a bottom Dock strip occupies within a
    /// tile — icon + tray + edge margin — so the resolution slider can sit above it.
    /// Mirrors the geometry in `drawDockIndicator`.
    func dockStripDepth(in tile: NSRect) -> CGFloat {
        let inset = tile.insetBy(dx: 1.5, dy: 1.5)
        let icon = min(max(inset.height * 0.10, 7), 15)
        let tray = icon * 0.34
        let margin = icon * 0.5
        return margin + icon + tray * 2 + 4   // + a little breathing room
    }

    private func drawDockIndicator(in tile: NSRect, edge: DockPredictor.Edge) {
        let inset = tile.insetBy(dx: 1.5, dy: 1.5)
        let horizontal = (edge == .bottom)            // bottom Dock runs left↔right
        // Icon size from the short dimension; the run centers along the long one.
        let icon = min(max((horizontal ? inset.height : inset.width) * 0.10, 7), 15)
        let gap = icon * 0.28                          // tight spacing between icons
        let preDivider = icon * 0.22                    // tight gap on the divider's left
        let postDivider = icon * 0.34                   // a smidge more on the right
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
        // Monitors are neutral now — color lives on the seams (the bars), not the tiles.
        // A light gray reads as a "screen" against the darker backdrop; the selected tile
        // takes a light wash of the *system accent* and lifts via `drawSelectedShadow`.
        let selected = display.id == selectedID
        let color = selected
            ? NSColor.controlAccentColor.blended(withFraction: 0.78, of: .white) ?? .white
            : NSColor(white: 0.72, alpha: 0.85)
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)
        color.setFill(); path.fill()
        color.setStroke(); path.lineWidth = 1.5; path.stroke()
        drawWallpaper(for: display, in: inset, selected: selected)
        drawBoxing(for: display, in: inset, color: color)
        // Centered name/resolution/ppi, with the pinned resolution slider on the selected tile.
        drawLabel(for: display, in: inset, selected: selected, viewScale: scale, tileColor: color)
        // The main display carries a menu-bar strip (drag it to another tile to move main).
        if display.isMain, draggingMenuBar == nil { drawMenuBar(in: menuBarRect(inTile: inset)) }
    }

    /// Fill the tile with what's actually on that screen: a live capture frame (the real
    /// desktop + windows, minus Silkscreen's own overlay) when available, else the static
    /// wallpaper. Clipped to the rounded tile and scaled to cover. A mirrored slave shows
    /// its master's content. Dimmed slightly so labels/bars stay legible on top.
    private func drawWallpaper(for display: DisplaySnapshot, in tile: NSRect, selected: Bool) {
        let sourceID = display.mirrorMaster ?? display.id
        // Prefer the live capture (only when the feed is enabled); fall back to the static
        // wallpaper. Both are reduced to a CGImage and drawn through one orientation-
        // correct primitive.
        let live = state.feedEnabled ? state.capture?.frames[sourceID] : nil
        let image = live ?? wallpaper(for: display)?.asCGImage
        guard let image else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: tile, xRadius: tileCornerRadius, yRadius: tileCornerRadius).addClip()
        drawImageAspectFill(image, in: tile, alpha: selected ? 1.0 : 0.95)

        // A very faint scrim so seam bars/anchors keep contrast against busy content
        // (the info block has its own plate now, so this can be light).
        NSColor.black.withAlphaComponent(selected ? 0.06 : 0.12).setFill()
        tile.fill()
    }

    /// Draw `image` aspect-filled (cover, center-crop) into `rect`.
    func drawImageAspectFill(_ image: CGImage, in rect: NSRect, alpha: CGFloat = 1) {
        guard let ctx = NSGraphicsContext.current?.cgContext, image.width > 0, image.height > 0 else { return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let w = iw * scale, h = ih * scale
        let dst = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)

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

    /// If the current (or previewed) mode's aspect ratio doesn't match the panel's
    /// physical shape, the image is letter-/pillar-boxed. Draw the actual image area as
    /// an inset rectangle and hatch the black-bar regions so it's obvious.
    private func drawBoxing(for display: DisplaySnapshot, in tile: NSRect, color: NSColor) {
        // Image aspect from the current or pending pixel resolution.
        let pending = state.pendingMode(for: display.id)
        let imgW = Double(pending?.pixelWidth ?? Int(display.pixelSize.width))
        let imgH = Double(pending?.pixelHeight ?? Int(display.pixelSize.height))
        // Compare the image aspect against the panel's native pixel aspect.
        guard imgW > 0, imgH > 0, let panAspect = nativeAspect(display.id) else { return }
        let imgAspect = imgW / imgH
        guard abs(imgAspect - panAspect) / panAspect > 0.02 else { return }   // fills the panel

        // The image rect: the largest tile-centered rect with the image's aspect.
        var img = tile.insetBy(dx: 2, dy: 2)
        if imgAspect > panAspect {                 // wider than panel → letterbox (bars top/bottom)
            let h = img.width / CGFloat(imgAspect)
            img = NSRect(x: img.minX, y: img.midY - h / 2, width: img.width, height: h)
        } else {                                   // narrower → pillarbox (bars left/right)
            let w = img.height * CGFloat(imgAspect)
            img = NSRect(x: img.midX - w / 2, y: img.minY, width: w, height: img.height)
        }
        // Outline the image area; hatch the boxed (black-bar) regions with diagonal lines.
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

        // The label is a *true-size preview* of UI at the selected resolution: a base
        // font of N points occupies (N / pointsPerInch) inches on the real panel, which
        // maps into the mini-map as `× viewScale` (view px per inch). So the faithful
        // on-tile font scale is `viewScale / pointsPerInch` — sliding the resolution
        // grows/shrinks the text just as macOS will (lower res → fewer ppi → bigger), and
        // the same real element reads the same physical size across every tile. At real
        // mini-map zooms that's a few px (UI text really is tiny at this scale), so a
        // constant gain `k` lifts it to a legible range *without distorting the ratios*
        // between screens; a floor catches the dense/zoomed-out extremes.
        let previewGain: CGFloat = 5.25   // 1.5× the base legibility gain
        let previewScale = effPPI.map { viewScale / CGFloat($0) * previewGain } ?? (rect.height / 100)
        let fontScale = max(0.525, previewScale)
        func f(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            let base = bold ? NSFont.boldSystemFont(ofSize: size * fontScale) : .systemFont(ofSize: size * fontScale)
            return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        }

        // On the selected (accent-tinted) tile, text is a deep saturated accent so it
        // stays legible against the blue-white and reads as "active" — not white-on-white.
        let accent = NSColor.controlAccentColor
        let primary = selected ? (accent.blended(withFraction: 0.72, of: .black) ?? accent) : .labelColor
        let secondary = selected ? (accent.blended(withFraction: 0.55, of: .black) ?? accent) : .secondaryLabelColor

        // The text lines (name, resolution, diagonal·ppi). These *scale* with the tile
        // to preview resolution, so they must not shove the slider around.
        var lines: [(String, NSFont, NSColor)] = []
        lines.append((display.name, f(16, bold: true), primary))
        let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
        lines.append(("\(Int(sz.width))×\(Int(sz.height))" + hidpi, f(13), primary))
        let diag = display.diagonalInches > 0 ? String(format: "%.0f″ · ", display.diagonalInches) : ""
        if let effPPI {
            lines.append((diag + String(format: "%.0f ppi", effPPI), f(13), secondary))
        } else {
            lines.append((diag + "calibrate?", f(13), secondary))
        }

        // Text is centered in the *whole* tile. The slider is pinned to a fixed spot near
        // the tile bottom (clear of a bottom Dock strip) — it never moves as the text
        // zooms. If large text reaches the slider, the slider is drawn *last*, on top, over
        // an opaque plate that masks the text beneath it.
        let gap: CGFloat = 3
        let sizes = lines.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]) }
        let total = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(lines.count - 1)
        // The block is vertically centered; `bottom` is its lower edge.
        let bottom = rect.midY - total / 2

        // A rounded translucent plate behind the info block so it reads against the
        // wallpaper. Sized to the widest visible line, capped to the tile.
        let visibleWidths = sizes.filter { $0.width <= rect.width - 8 }.map(\.width)
        if let widest = visibleWidths.max() {
            let padX: CGFloat = 11, padY: CGFloat = 6
            let boxW = min(widest + padX * 2, rect.width - 4)
            let box = NSRect(x: rect.midX - boxW / 2, y: bottom - padY,
                             width: boxW, height: total + padY * 2)
            // A light plate under the (dark) label text so it reads over any wallpaper.
            let fill = selected
                ? NSColor.white.withAlphaComponent(0.6)
                : NSColor(white: 0.9, alpha: 0.44)
            fill.setFill()
            NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
        }

        // Stack lines top-down (y-up): start at the block's top and drop each line's height.
        var y = bottom + total
        for (i, (text, font, color)) in lines.enumerated() {
            let s = sizes[i]
            y -= s.height
            if s.width <= rect.width - 8 {
                (text as NSString).draw(at: CGPoint(x: rect.midX - s.width / 2, y: y),
                                        withAttributes: [.font: font, .foregroundColor: color])
            }
            y -= gap
        }
        // The resolution slider now lives in the bottom control cluster (between Undo and
        // Done), acting on the selected display — no longer drawn on the tile.
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

    private func drawFooter(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: 8), withAttributes: attrs)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
