import AppKit

/// The right-hand column overlay: read-only cards for mirrored displays (name /
/// resolution / what they mirror, with an un-mirror button) and a macOS-managed
/// AirPlay session. Screen-anchored UI drawn on top of the schematic, unrelated to
/// the physical plane.
extension Arranger {

    /// One compact card per mirrored display, plus an un-mirror button.
    func drawMirrorColumn() {
        unmirrorButtonRects.removeAll()
        airplaySettingsButtonRect = nil
        let mirrored = mirroredDisplays
        guard !mirrored.isEmpty || airplaySession != nil else { return }
        let colW = mirrorColumnWidth
        let colX = bounds.width - colW
        let pad: CGFloat = 18
        let cardW = colW - pad * 2       // fixed width; height follows each screen's aspect
        let gap: CGFloat = 16
        // Stacks top-down: `y` is the next element's top edge (view y-up, so subtract).
        var y = bounds.height - outerPadding

        let hAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        if !mirrored.isEmpty {
            y -= 18   // header text height
            (Copy.mirroredHeader as NSString).draw(at: CGPoint(x: colX + pad, y: y), withAttributes: hAttrs)
            y -= 8
        }

        for d in mirrored {
            // Height from the screen's aspect, clamped so the text still fits.
            let sz0 = pointSize(d)
            let aspect = sz0.height > 0 ? sz0.width / sz0.height : 16.0 / 9
            let cardH = min(max(cardW / max(aspect, 0.1), 120), 260)
            let card = NSRect(x: colX + pad, y: y - cardH, width: cardW, height: cardH)
            // Dark card so the drag name's glow reads as a glow, not a smudge.
            NSColor(white: 0.12, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()

            let inner = card.insetBy(dx: 18, dy: 16)
            var ty = inner.maxY
            func line(_ s: String, _ font: NSFont, _ color: NSColor, glow: NSColor? = nil) {
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if let glow {
                    let shadow = NSShadow()
                    shadow.shadowColor = glow
                    shadow.shadowBlurRadius = 6
                    shadow.shadowOffset = .zero
                    a[.shadow] = shadow
                }
                let h = (s as NSString).size(withAttributes: a).height
                ty -= h
                (s as NSString).draw(at: CGPoint(x: inner.minX, y: ty), withAttributes: a)
                ty -= 5
            }
            let nameGlow = NSColor.systemPink.blended(withFraction: 0.55, of: .white) ?? .white
            line(d.nickname, DragFont.script(size: 30), .systemPink, glow: nameGlow)
            line(d.name, .systemFont(ofSize: 10), NSColor.white.withAlphaComponent(0.5))
            let sz = pointSize(d)
            let pixelW = Int(d.pixelSize.width)
            let hidpi = pixelW > Int(sz.width) ? " HiDPI" : ""
            line("\(Int(sz.width))×\(Int(sz.height))\(hidpi)", .systemFont(ofSize: 15), .white)
            let effPPI = d.diagonalInches > 0 && sz.width > 0
                ? Double(sz.width) / (Double(d.physicalSizeMM.width) / 25.4) : nil
            let diag = d.diagonalInches > 0 ? String(format: "%.0f″ · ", d.diagonalInches) : ""
            let dim = NSColor.white.withAlphaComponent(0.7)
            if let effPPI {
                line(diag + String(format: "%.0f ppi", effPPI), .systemFont(ofSize: 15), dim)
            } else if !diag.isEmpty {
                line(String(diag.dropLast(3)), .systemFont(ofSize: 15), dim)
            }
            let masterName = displays.first { $0.id == d.mirrorMaster }?.name ?? Copy.unknownDisplayName
            line(Copy.mirrorsLine(masterName), .systemFont(ofSize: 15), dim)

            // Un-mirror button (top-right ✕).
            let bx = NSRect(x: card.maxX - 34, y: card.maxY - 34, width: 24, height: 24)
            NSColor(white: 0.4, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: bx).fill()
            let x: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let xs = ("✕" as NSString).size(withAttributes: x)
            ("✕" as NSString).draw(at: CGPoint(x: bx.midX - xs.width / 2, y: bx.midY - xs.height / 2), withAttributes: x)
            unmirrorButtonRects[d.id] = bx

            y -= cardH + gap
        }

        if let session = airplaySession {
            drawAirPlayCard(session, colX: colX, pad: pad, cardW: cardW, y: &y, hAttrs: hAttrs)
        }
    }

    /// A read-only card for a macOS-managed AirPlay *visual* session — it can have no
    /// `CGDirectDisplay` ("Window or App" mode), hence a card and not a plane tile. We
    /// can detect it but not cancel it, so the action hands off to system settings.
    private func drawAirPlayCard(
        _ session: AirPlaySession, colX: CGFloat, pad: CGFloat, cardW: CGFloat,
        y: inout CGFloat, hAttrs: [NSAttributedString.Key: Any]
    ) {
        y -= 18   // header text height
        (Copy.airplayHeader as NSString).draw(at: CGPoint(x: colX + pad, y: y), withAttributes: hAttrs)
        y -= 8

        let cardH: CGFloat = 140
        let card = NSRect(x: colX + pad, y: y - cardH, width: cardW, height: cardH)
        NSColor(white: 0.72, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()

        let inner = card.insetBy(dx: 18, dy: 16)
        var ty = inner.maxY
        func line(_ s: String, _ font: NSFont, _ color: NSColor) {
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let bounding = (s as NSString).boundingRect(
                with: CGSize(width: inner.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: a)
            ty -= bounding.height
            (s as NSString).draw(with: CGRect(x: inner.minX, y: ty, width: inner.width, height: bounding.height),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: a)
            ty -= 5
        }

        // Device name, with the AirPlay glyph inline before it.
        let nameFont = NSFont.boldSystemFont(ofSize: 20)
        let name = (session.receiverName ?? Copy.unknownAirPlayReceiver) as NSString
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: NSColor.labelColor]
        ty -= name.size(withAttributes: nameAttrs).height   // drop to this line's baseline (y-up)
        var nameX = inner.minX
        if let icon = NSImage(systemSymbolName: "airplayvideo", accessibilityDescription: "AirPlay") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            let glyph = (icon.withSymbolConfiguration(cfg) ?? icon)
            glyph.isTemplate = true
            let gh = glyph.size.height, gw = glyph.size.width
            // Vertically center the glyph on the name's cap height.
            let iconRect = NSRect(x: nameX, y: ty + (nameFont.ascender - gh) / 2 + 2, width: gw, height: gh)
            NSColor.labelColor.set()
            glyph.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            nameX = iconRect.maxX + 8
        }
        name.draw(at: CGPoint(x: nameX, y: ty), withAttributes: nameAttrs)
        ty -= 5
        line(Copy.airplayBody, .systemFont(ofSize: 15), .labelColor)
        line(Copy.airplayFinePrint,
             .systemFont(ofSize: 13), .secondaryLabelColor)

        // Hands off to Control Center's Screen Mirroring menu (Display Settings doesn't
        // know about AirPlay sessions).
        let btn = NSRect(x: inner.minX, y: ty - 6 - 28, width: 168, height: 28)
        NSColor(white: 0.4, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: btn, xRadius: 6, yRadius: 6).fill()
        let ba: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let label = Copy.airplayOpenSettings as NSString
        let ls = label.size(withAttributes: ba)
        label.draw(at: CGPoint(x: btn.midX - ls.width / 2, y: btn.midY - ls.height / 2), withAttributes: ba)
        airplaySettingsButtonRect = btn

        y -= cardH + 16
    }
}
