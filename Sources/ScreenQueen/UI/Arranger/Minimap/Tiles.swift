import SwiftUI

fileprivate extension NSImage {
    /// This image as a `CGImage` (full bounds), or nil. Deliberately file-scoped —
    /// it exists for the wallpaper draw, not as a general bridge.
    var asCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// One tile: fill, wallpaper/live feed, letterbox hatching, menu-bar strip, Dock
/// indicator, the selected halo, and the info-card feed. Native GraphicsContext,
/// one y-down space throughout.
extension Minimap {

    func drawTile(_ ctx: GraphicsContext, for display: DisplaySnapshot, in rect: NSRect) {
        // Tiles stay neutral — color lives on the seams; selection gets the accent wash.
        let selected = display.id == state.selectedID
        let color = Color(nsColor: selected
            ? NSColor.systemPink.blended(withFraction: 0.75, of: .white) ?? .white
            : NSColor(white: 0.72, alpha: 0.85))
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = Path(roundedRect: inset, cornerRadius: tileCornerRadius)
        ctx.fill(path, with: .color(color))
        ctx.stroke(path, with: .color(color), lineWidth: 1.5)
        drawWallpaper(ctx, for: display, in: inset, selected: selected)
        drawBoxing(ctx, for: display, in: inset)
        // The main display carries a menu-bar strip (drag it to another tile to move main).
        if display.isMain, stage.draggingMenuBar == nil { drawMenuBar(ctx, in: menuBarRect(inTile: inset)) }
    }

    /// A pink glow halo behind the selected tile, drawn *before* it so only the blur
    /// bleeds out (seam glitter, drawn later, is untouched). Two passes: wide soft
    /// bloom, then a tight bright ring.
    func drawSelectedShadow(_ ctx: GraphicsContext, _ tileRect: NSRect) {
        let path = Path(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
                        cornerRadius: tileCornerRadius)
        for (blur, alpha) in [(30.0, 0.55), (12.0, 0.95)] as [(CGFloat, CGFloat)] {
            var glow = ctx
            // Even glow, not a drop shadow (offset zero).
            glow.addFilter(.shadow(color: Color.pink.opacity(alpha),
                                   radius: blur, x: 0, y: 0))
            glow.fill(path, with: .color(.black))
        }
    }

    /// The macOS Dock in miniature (3 squircles · divider · Trash) hugging the predicted
    /// Dock edge of a tile.
    func drawDockIndicator(_ ctx: GraphicsContext, in tile: NSRect, edge: DockPredictor.Edge) {
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
        case .bottom: depthLo = inset.maxY - margin - icon   // maxY is the screen bottom
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
        ctx.fill(Path(roundedRect: trayRect, cornerRadius: trayR),
                 with: .color(Color(white: 0.32).opacity(0.6)))

        func squircle(_ rect: NSRect) {
            ctx.fill(Path(roundedRect: rect, cornerRadius: r),
                     with: .color(.white.opacity(0.92)))
        }

        var a = startA
        for i in 0..<3 { squircle(square(at: a)); a += icon + (i < 2 ? gap : preDivider) }  // 3 icons, tight then pre-divider gap
        // Divider line spanning the icon depth, across the Dock axis.
        let s = square(at: a)
        let line: NSRect = horizontal
            ? NSRect(x: a, y: s.minY + icon * 0.1, width: lineThick, height: icon * 0.8)
            : NSRect(x: s.minX + icon * 0.1, y: a, width: icon * 0.8, height: lineThick)
        ctx.fill(Path(roundedRect: line, cornerRadius: min(line.width, line.height) / 2),
                 with: .color(.white.opacity(0.5)))
        a += lineThick + postDivider
        squircle(square(at: a))                                     // 4th icon (Trash)
    }

    /// Fill the tile with what's on that screen: a live capture frame when the feed is
    /// on, else the static wallpaper. A mirrored slave shows its master's content.
    private func drawWallpaper(_ ctx: GraphicsContext, for display: DisplaySnapshot, in tile: NSRect, selected: Bool) {
        let sourceID = display.mirrorMaster ?? display.id
        let live = state.feedEnabled ? state.capture?.frames[sourceID] : nil
        let image = live ?? wallpaper(for: display)?.asCGImage
        guard let image else { return }

        var clipped = ctx
        clipped.clip(to: Path(roundedRect: tile, cornerRadius: tileCornerRadius))
        drawImageAspectFill(clipped, image, in: tile, alpha: selected ? 1.0 : 0.95)

        // A faint scrim so seam bars/anchors keep contrast against busy content.
        clipped.fill(Path(tile), with: .color(.black.opacity(selected ? 0.06 : 0.12)))
    }

    /// Draw `image` aspect-filled (cover, center-crop) into `rect`.
    private func drawImageAspectFill(_ ctx: GraphicsContext, _ image: CGImage, in rect: NSRect, alpha: CGFloat = 1) {
        guard image.width > 0, image.height > 0 else { return }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let w = iw * scale, h = ih * scale
        // Pixel-snap the destination: a sub-pixel origin softens the whole image, and the
        // cover-crop already bleeds past the tile so a ≤1px nudge is free.
        let dst = NSRect(x: stage.pixelSnap(rect.midX - w / 2), y: stage.pixelSnap(rect.midY - h / 2),
                         width: stage.pixelSnap(w), height: stage.pixelSnap(h))
        var c = ctx
        c.opacity = alpha
        c.draw(Image(decorative: image, scale: 1), in: dst)
    }

    /// The desktop wallpaper for `display` (its master, if mirrored), cached and
    /// reloaded when the wallpaper URL changes.
    private func wallpaper(for display: DisplaySnapshot) -> NSImage? {
        let id = display.mirrorMaster ?? display.id
        guard let screen = NSScreen.screen(for: id),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
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
    private func drawBoxing(_ ctx: GraphicsContext, for display: DisplaySnapshot, in tile: NSRect) {
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
        ctx.stroke(Path(img), with: .color(.black.opacity(0.35)), lineWidth: 1)
        hatch(ctx, tile.insetBy(dx: 2, dy: 2), excluding: img, opacity: 0.3)
    }

    /// Native pixel aspect for `id`, cached in `nativeAspectCache`.
    func nativeAspect(_ id: CGDirectDisplayID) -> Double? {
        if let cached = nativeAspectCache[id] { return cached }
        let a = ModeCatalog.nativeAspect(for: id)
        nativeAspectCache[id] = a
        return a
    }

    /// Fill the region of `rect` outside `hole` with faint diagonal hatch lines.
    private func hatch(_ ctx: GraphicsContext, _ rect: NSRect, excluding hole: NSRect, opacity: Double) {
        var clip = Path(rect)
        clip.addPath(Path(hole))
        var c = ctx
        c.clip(to: clip, style: FillStyle(eoFill: true))   // even-odd hole
        var lines = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            // "/" strokes: bottom-left → top-right.
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        c.stroke(lines, with: .color(.black.opacity(opacity)), lineWidth: 1)
    }

    /// The menu-bar strip across the top of a tile.
    func menuBarRect(inTile tile: NSRect) -> NSRect {
        let h = min(18, tile.height * 0.2)
        return NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: h)
    }

    func drawMenuBar(_ ctx: GraphicsContext, in rect: NSRect) {
        ctx.fill(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                 with: .color(.white.opacity(0.6)))
    }

    /// Place/update every tile's frosted info card, and hide cards for displays not on
    /// the plane this pass. Subview work, so it lives on the refresh path — `draw(_:)`
    /// must not mutate the view tree (a Canvas port can't).
    func layoutLabelCards() {
        let rects = state.plane
        guard let t = stage.drawTransform(rects) else {
            labelCards.values.forEach { $0.isHidden = true }
            return
        }
        var placed = Set<CGDirectDisplayID>()
        for d in state.displays {
            guard let r = rects[d.id] else { continue }
            placed.insert(d.id)
            layoutLabelCard(for: d, in: t.viewRect(r).insetBy(dx: 1.5, dy: 1.5),
                            selected: d.id == state.selectedID, viewScale: t.scale)
        }
        for (id, card) in labelCards where !placed.contains(id) { card.isHidden = true }
    }

    private func layoutLabelCard(for display: DisplaySnapshot, in rect: NSRect, selected: Bool, viewScale: CGFloat) {
        let effPPI = state.effectivePPI(display)

        // True-size preview: the faithful on-tile font scale is `viewScale / ppi`, so
        // sliding the resolution grows/shrinks the text just as macOS will. A constant
        // gain lifts it to legible without distorting the ratios between screens.
        let previewGain: CGFloat = 5.25
        let previewScale = effPPI.map { viewScale / CGFloat($0) * previewGain } ?? (rect.height / 100)
        let fontScale = max(0.525, previewScale)
        func f(_ size: CGFloat) -> Font { .system(size: size * fontScale) }

        // Light-on-dark text; selected tiles lift it toward the accent.
        let accent = NSColor.systemPink
        let primary = selected ? (accent.blended(withFraction: 0.3, of: .white) ?? accent) : .white
        let secondary = selected ? (accent.blended(withFraction: 0.5, of: .white) ?? accent) : NSColor.white.withAlphaComponent(0.7)
        let tertiary = secondary.withAlphaComponent(0.72)

        // Drag name (hot-pink script), government name (fine print — work names go in
        // baby letters), resolution, diagonal·ppi.
        let stats = state.statLines(for: display)
        var lines: [LabelCardContent.Line] = []
        lines.append(.init(text: display.nickname, font: .script(size: (26 * fontScale).rounded()), color: .pink))
        lines.append(.init(text: display.name, font: f(10), color: Color(nsColor: tertiary)))
        lines.append(.init(text: stats.resolution, font: f(13), color: Color(nsColor: primary)))
        lines.append(.init(text: stats.detail, font: f(13), color: Color(nsColor: secondary)))

        // The card sizes itself; the stage just centers the fitting size on the tile,
        // capping the width (long lines truncate) and hiding it when the tile is too
        // short to hold it.
        let card = ensureLabelCard(for: display.id)
        card.update(LabelCardContent(lines: lines, selected: selected))
        let size = card.fittingSize
        guard size.height <= rect.height - 4 else {
            card.isHidden = true
            return
        }
        let boxW = min(size.width, rect.width - 4)
        // Pixel-snap the card's frame — the text snap inside it is only meaningful if
        // the card's own origin sits on the grid.
        card.frame = NSRect(x: stage.pixelSnap(rect.midX - boxW / 2), y: stage.pixelSnap(rect.midY - size.height / 2),
                            width: stage.pixelSnap(boxW), height: stage.pixelSnap(size.height))
        card.isHidden = false
    }

    /// The frosted info card for `id`, created on demand and added above the drawn tiles.
    private func ensureLabelCard(for id: CGDirectDisplayID) -> LabelCardHost {
        if let c = labelCards[id] { return c }
        let c = LabelCardHost(rootView: LabelCardView(content: LabelCardContent()))
        stage.addSubview(c)
        labelCards[id] = c
        return c
    }
}
