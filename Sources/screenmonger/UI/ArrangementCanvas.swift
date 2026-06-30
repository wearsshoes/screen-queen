import AppKit

/// Interactive visualization of the display arrangement.
///
/// Tiles are drawn scaled-to-fit, mirroring the live global desktop layout.
/// Dragging a tile updates a *working* origin (the real displays don't move
/// until drop), with edge-snapping against neighbors. On drop, `onCommit` hands
/// the desired origins to the owner to apply + confirm.
final class ArrangementCanvas: NSView {

    /// Called on drop with the desired global origin for every display.
    var onCommit: (([CGDirectDisplayID: CGPoint]) -> Void)?

    /// Called during a drag whenever the resolved placement changes, so the real
    /// displays can be repositioned live. Fires only on slot changes (not every
    /// pixel) because `resolve` snaps to discrete adjacent placements.
    var onDragUpdate: (([CGDirectDisplayID: CGPoint]) -> Void)?

    /// Called when the user picks "Set as Main Display" from a tile's context menu.
    var onSetMain: ((CGDirectDisplayID) -> Void)?

    /// Called when the user picks a resolution from a tile's context menu.
    var onSetMode: ((CGDirectDisplayID, CGDisplayMode) -> Void)?

    /// Called to calibrate / reset a display's physical size.
    var onCalibrate: ((CGDirectDisplayID) -> Void)?
    var onCalibrateVisual: ((CGDirectDisplayID) -> Void)?
    var onResetCalibration: ((CGDirectDisplayID) -> Void)?

    private var displays: [DisplaySnapshot] = []

    /// Per-display origin overrides applied during a drag (global points).
    private var workingOrigins: [CGDirectDisplayID: CGPoint] = [:]

    private var draggedID: CGDirectDisplayID?
    private var dragStartMouse: CGPoint = .zero
    private var dragStartOrigin: CGPoint = .zero
    /// Whether the active drag has actually relocated the tile (a bare click won't).
    private var dragMoved = false

    private let outerPadding: CGFloat = 32
    private let tileCornerRadius: CGFloat = 8

    // Match CoreGraphics global space: origin top-left, y downward.
    override var isFlipped: Bool { true }

    func update(with displays: [DisplaySnapshot]) {
        self.displays = displays
        workingOrigins.removeAll()
        draggedID = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    /// Effective bounds for a display, honoring any in-progress drag override.
    private func effectiveBounds(_ d: DisplaySnapshot) -> CGRect {
        CGRect(origin: workingOrigins[d.id] ?? d.bounds.origin, size: d.bounds.size)
    }

    /// Maps the global point space onto the view's drawing area.
    private struct Transform {
        let scale: CGFloat
        let offset: CGPoint
        let unionOrigin: CGPoint

        func viewRect(forGlobal r: CGRect) -> CGRect {
            CGRect(
                x: offset.x + (r.minX - unionOrigin.x) * scale,
                y: offset.y + (r.minY - unionOrigin.y) * scale,
                width: r.width * scale,
                height: r.height * scale
            )
        }
    }

    private func currentTransform() -> Transform? {
        guard !displays.isEmpty else { return nil }
        let rects = displays.map(effectiveBounds)
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }

        let availW = bounds.width - outerPadding * 2
        let availH = bounds.height - outerPadding * 2
        let scale = min(availW / union.width, availH / union.height)
        let offset = CGPoint(
            x: outerPadding + (availW - union.width * scale) / 2,
            y: outerPadding + (availH - union.height * scale) / 2
        )
        return Transform(scale: scale, offset: offset, unionOrigin: union.origin)
    }

    // MARK: - Mouse / dragging

    override func mouseDown(with event: NSEvent) {
        guard let t = currentTransform() else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Topmost first.
        for d in displays.reversed() where t.viewRect(forGlobal: effectiveBounds(d)).contains(p) {
            draggedID = d.id
            dragStartMouse = p
            dragStartOrigin = effectiveBounds(d).origin
            dragMoved = false
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = draggedID, let t = currentTransform(),
              let dragged = displays.first(where: { $0.id == id }) else { return }

        let p = convert(event.locationInWindow, from: nil)
        let deltaGlobal = CGPoint(
            x: (p.x - dragStartMouse.x) / t.scale,
            y: (p.y - dragStartMouse.y) / t.scale
        )
        let freeOrigin = CGPoint(x: dragStartOrigin.x + deltaGlobal.x,
                                 y: dragStartOrigin.y + deltaGlobal.y)

        // Show the resolved (gap-free, non-overlapping) placement live, not the
        // raw cursor position — this is where the display would actually land.
        let others = displays.filter { $0.id != id }.map(effectiveBounds)
        let resolved = resolve(size: dragged.bounds.size, freeOrigin: freeOrigin, against: others)
        guard resolved != workingOrigins[id] else { return } // only act on slot changes
        workingOrigins[id] = resolved
        if abs(resolved.x - dragStartOrigin.x) > 0.5 || abs(resolved.y - dragStartOrigin.y) > 0.5 {
            dragMoved = true
        }
        needsDisplay = true
        if dragMoved { onDragUpdate?(currentOrigins()) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedID = nil; dragMoved = false }
        guard draggedID != nil else { return }
        // A click without a real move shouldn't reconfigure anything.
        guard dragMoved else { needsDisplay = true; return }
        onCommit?(currentOrigins())
    }

    private func currentOrigins() -> [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, effectiveBounds($0).origin) })
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let t = currentTransform() else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        for d in displays.reversed() where t.viewRect(forGlobal: effectiveBounds(d)).contains(p) {
            let menu = NSMenu()
            menu.addItem(withTitle: d.name, action: nil, keyEquivalent: "")
            menu.addItem(.separator())

            let mainItem = NSMenuItem(title: "Set as Main Display",
                                      action: #selector(setMainFromMenu(_:)), keyEquivalent: "")
            mainItem.target = self
            mainItem.representedObject = NSNumber(value: d.id)
            mainItem.isEnabled = !d.isMain
            menu.addItem(mainItem)

            menu.addItem(resolutionMenuItem(for: d))

            menu.addItem(.separator())
            if displays.count > 1 {
                let matchItem = NSMenuItem(title: "Calibrate by Matching…",
                                           action: #selector(calibrateVisualFromMenu(_:)), keyEquivalent: "")
                matchItem.target = self
                matchItem.representedObject = NSNumber(value: d.id)
                menu.addItem(matchItem)
            }
            let calItem = NSMenuItem(title: "Calibrate by Diagonal…",
                                     action: #selector(calibrateFromMenu(_:)), keyEquivalent: "")
            calItem.target = self
            calItem.representedObject = NSNumber(value: d.id)
            menu.addItem(calItem)

            if d.physicalSizeIsCalibrated {
                let resetItem = NSMenuItem(title: "Reset Size to EDID",
                                           action: #selector(resetCalibrationFromMenu(_:)), keyEquivalent: "")
                resetItem.target = self
                resetItem.representedObject = NSNumber(value: d.id)
                menu.addItem(resetItem)
            }
            return menu
        }
        return nil
    }

    private func resolutionMenuItem(for d: DisplaySnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = CGDisplayCopyDisplayMode(d.id)
        for mode in ModeCatalog.menuModes(for: d.id) {
            let mi = NSMenuItem(title: mode.label, action: #selector(setModeFromMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ModeChoice(id: d.id, mode: mode.cgMode)
            if let current, ModeCatalog.sameMode(current, mode.cgMode) { mi.state = .on }
            submenu.addItem(mi)
        }
        item.submenu = submenu
        return item
    }

    /// Carries both the display id and chosen CGDisplayMode through a menu item.
    private final class ModeChoice {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        init(id: CGDirectDisplayID, mode: CGDisplayMode) { self.id = id; self.mode = mode }
    }

    @objc private func setMainFromMenu(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onSetMain?(number.uint32Value)
    }

    @objc private func setModeFromMenu(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ModeChoice else { return }
        onSetMode?(choice.id, choice.mode)
    }

    @objc private func calibrateFromMenu(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onCalibrate?(number.uint32Value)
    }

    @objc private func calibrateVisualFromMenu(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onCalibrateVisual?(number.uint32Value)
    }

    @objc private func resetCalibrationFromMenu(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        onResetCalibration?(number.uint32Value)
    }

    /// Resolve a free cursor position into the nearest *valid* placement: the
    /// dragged display is set flush against one neighbor's edge (no gap), slid
    /// along that edge toward the cursor, and rejected if it would overlap any
    /// display. This mirrors how the arrangement will actually be normalized, so
    /// the preview stays plausible throughout the drag.
    private func resolve(size: CGSize, freeOrigin: CGPoint, against others: [CGRect]) -> CGPoint {
        guard !others.isEmpty else { return freeOrigin }

        var best = freeOrigin
        var bestDist = CGFloat.greatestFiniteMagnitude

        for o in others {
            // Slide range so the dragged rect keeps an overlapping edge segment
            // with `o` along the shared axis.
            let yAligned = clamp(freeOrigin.y, o.minY - size.height + 1, o.maxY - 1)
            let xAligned = clamp(freeOrigin.x, o.minX - size.width + 1, o.maxX - 1)

            let candidates = [
                CGPoint(x: o.maxX, y: yAligned),               // right of o
                CGPoint(x: o.minX - size.width, y: yAligned),  // left of o
                CGPoint(x: xAligned, y: o.maxY),               // below o
                CGPoint(x: xAligned, y: o.minY - size.height), // above o
            ]

            for c in candidates {
                let rect = CGRect(origin: c, size: size).insetBy(dx: 1, dy: 1)
                if others.contains(where: { $0.intersects(rect) }) { continue } // reject overlaps
                let d = hypot(c.x - freeOrigin.x, c.y - freeOrigin.y)
                if d < bestDist { bestDist = d; best = c }
            }
        }
        return best
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo <= hi ? min(max(v, lo), hi) : (lo + hi) / 2
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let t = currentTransform() else {
            drawCenteredMessage("No displays detected")
            return
        }

        for d in displays {
            drawTile(for: d, in: t.viewRect(forGlobal: effectiveBounds(d)), dragging: d.id == draggedID && dragMoved)
        }
        drawFooter("Drag a display to rearrange")
    }

    private func drawTile(for display: DisplaySnapshot, in rect: NSRect, dragging: Bool) {
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: tileCornerRadius, yRadius: tileCornerRadius)

        let fill: NSColor
        if dragging { fill = NSColor.controlAccentColor.withAlphaComponent(0.30) }
        else if display.isMain { fill = NSColor.controlAccentColor.withAlphaComponent(0.18) }
        else { fill = NSColor.controlColor }
        fill.setFill()
        path.fill()

        (display.isMain || dragging ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = (display.isMain || dragging) ? 2 : 1
        path.stroke()

        drawLabel(for: display, in: inset)
    }

    private func drawLabel(for display: DisplaySnapshot, in rect: NSRect) {
        var lines: [(String, NSFont)] = []
        lines.append((display.name + (display.isMain ? "  ●" : ""), .boldSystemFont(ofSize: 12)))

        let pts = "\(Int(display.bounds.width))×\(Int(display.bounds.height)) pt"
        let px = "\(Int(display.pixelSize.width))×\(Int(display.pixelSize.height)) px"
        lines.append((display.isHiDPI ? "\(pts)  (HiDPI \(px))" : pts, .systemFont(ofSize: 10)))

        if let ppi = display.ppi {
            let suffix = display.physicalSizeIsCalibrated
                ? String(format: " (calibrated %.0f\")", display.diagonalInches)
                : ""
            lines.append((String(format: "%.0f ppi%@", ppi, suffix), .systemFont(ofSize: 10)))
        } else {
            lines.append(("ppi: unknown (needs calibration)", .systemFont(ofSize: 10)))
        }
        if display.refreshHz > 0 {
            lines.append((String(format: "%.0f Hz", display.refreshHz), .systemFont(ofSize: 10)))
        }

        var y = rect.minY + 8
        for (text, font) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let size = (text as NSString).size(withAttributes: attrs)
            guard y + size.height <= rect.maxY - 4 else { break }
            (text as NSString).draw(at: CGPoint(x: rect.minX + 8, y: y), withAttributes: attrs)
            y += size.height + 2
        }
    }

    private func drawFooter(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                            y: bounds.height - size.height - 8),
                                withAttributes: attrs)
    }

    private func drawCenteredMessage(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        (message as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2,
                                               y: (bounds.height - size.height) / 2),
                                   withAttributes: attrs)
    }
}
