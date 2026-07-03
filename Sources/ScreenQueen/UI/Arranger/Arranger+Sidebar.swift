import SwiftUI

/// The right-hand column overlay: read-only cards for mirrored displays (name /
/// resolution / what they mirror, with an un-mirror button) and a macOS-managed
/// AirPlay session. Screen-anchored UI drawn on top of the schematic, unrelated to
/// the physical plane.
///
/// The column's *layout* is a pure function (`mirrorColumnLayout`): `draw` paints from
/// it and `mouseDown` hit-tests against it, so the two can't disagree and the draw
/// pass stores nothing.
extension Arranger {

    /// Where everything in the column sits, flowed top-down.
    struct MirrorColumnLayout {
        var mirroredHeaderOrigin: CGPoint?
        var cards: [(display: DisplaySnapshot, frame: NSRect)] = []
        var airplayHeaderOrigin: CGPoint?
        var airplayCard: NSRect?
    }

    /// The column layout as a pure function of state + bounds; nil when it holds nothing.
    func mirrorColumnLayout() -> MirrorColumnLayout? {
        let mirrored = mirroredDisplays
        guard !mirrored.isEmpty || airplaySession != nil else { return nil }
        var layout = MirrorColumnLayout()
        let colW = mirrorColumnWidth
        let colX = bounds.width - colW
        let pad: CGFloat = 18
        let cardW = colW - pad * 2       // fixed width; height follows each screen's aspect
        let gap: CGFloat = 16
        // Stacks top-down: `y` is the next element's top edge (view y-up, so subtract).
        var y = bounds.height - outerPadding

        if !mirrored.isEmpty {
            y -= 18   // header text height
            layout.mirroredHeaderOrigin = CGPoint(x: colX + pad, y: y)
            y -= 8
        }
        for d in mirrored {
            // Height from the screen's aspect, clamped so the text still fits.
            let sz = pointSize(d)
            let aspect = sz.height > 0 ? sz.width / sz.height : 16.0 / 9
            let cardH = min(max(cardW / max(aspect, 0.1), 120), 260)
            layout.cards.append((d, NSRect(x: colX + pad, y: y - cardH, width: cardW, height: cardH)))
            y -= cardH + gap
        }
        if airplaySession != nil {
            y -= 18
            layout.airplayHeaderOrigin = CGPoint(x: colX + pad, y: y)
            y -= 8
            let cardH: CGFloat = 140
            layout.airplayCard = NSRect(x: colX + pad, y: y - cardH, width: cardW, height: cardH)
        }
        return layout
    }

    /// The un-mirror button (top-right ✕) within a card.
    static func unmirrorButtonRect(inCard card: NSRect) -> NSRect {
        NSRect(x: card.maxX - 34, y: card.maxY - 34, width: 24, height: 24)
    }

    /// The "Open Settings" button, pinned to the AirPlay card's bottom-left.
    static func airplayButtonRect(inCard card: NSRect) -> NSRect {
        NSRect(x: card.minX + 18, y: card.minY + 14, width: 168, height: 28)
    }

    enum MirrorColumnHit {
        case unmirror(CGDirectDisplayID)
        case airplaySettings
    }

    /// What a click at `p` hits in the column, if anything.
    func mirrorColumnHit(at p: CGPoint) -> MirrorColumnHit? {
        guard let layout = mirrorColumnLayout() else { return nil }
        for (d, frame) in layout.cards where Self.unmirrorButtonRect(inCard: frame).contains(p) {
            return .unmirror(d.id)
        }
        if let card = layout.airplayCard, Self.airplayButtonRect(inCard: card).contains(p) {
            return .airplaySettings
        }
        return nil
    }

    /// One compact card per mirrored display, plus the AirPlay card. Native
    /// GraphicsContext drawing; measurement stays NSString (pure math) so the top-down
    /// stacking matches the AppKit-era layout exactly.
    func drawMirrorColumn(_ ctx: GraphicsContext) {
        guard let layout = mirrorColumnLayout() else { return }
        func header(_ s: String, at oUp: CGPoint) {
            let h = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).height
            ctx.draw(Text(s).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor)),
                     at: CGPoint(x: oUp.x, y: bounds.height - oUp.y - h), anchor: .topLeading)
        }
        if let o = layout.mirroredHeaderOrigin { header(Copy.mirroredHeader, at: o) }
        for (d, card) in layout.cards { drawMirrorCard(ctx, d, in: card) }
        if let session = airplaySession, let card = layout.airplayCard {
            if let o = layout.airplayHeaderOrigin { header(Copy.airplayHeader, at: o) }
            drawAirPlayCard(ctx, session, in: card)
        }
    }

    private func drawMirrorCard(_ ctx: GraphicsContext, _ d: DisplaySnapshot, in card: NSRect) {
        // Dark card so the drag name's glow reads as a glow, not a smudge.
        ctx.fill(Path(roundedRect: yDown(card), cornerRadius: 12),
                 with: .color(Color(white: 0.12).opacity(0.9)))

        let inner = card.insetBy(dx: 18, dy: 16)
        var ty = inner.maxY
        func line(_ s: String, _ font: NSFont, _ color: NSColor, glow: NSColor? = nil) {
            let h = (s as NSString).size(withAttributes: [.font: font]).height
            ty -= h
            var c = ctx
            if let glow {
                c.addFilter(.shadow(color: Color(nsColor: glow), radius: 6, x: 0, y: 0))
            }
            c.draw(Text(s).font(Font(font)).foregroundStyle(Color(nsColor: color)),
                   at: CGPoint(x: inner.minX, y: bounds.height - ty - h), anchor: .topLeading)
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

        // Un-mirror button (top-right ✕), at the same rect the hit test answers for.
        let bx = yDown(Self.unmirrorButtonRect(inCard: card))
        ctx.fill(Path(ellipseIn: bx), with: .color(Color(white: 0.4).opacity(0.9)))
        ctx.draw(Text("✕").font(.system(size: 15, weight: .bold)).foregroundStyle(.white),
                 at: CGPoint(x: bx.midX, y: bx.midY))
    }

    /// A read-only card for a macOS-managed AirPlay *visual* session — it can have no
    /// `CGDirectDisplay` ("Window or App" mode), hence a card and not a plane tile. We
    /// can detect it but not cancel it, so the action hands off to system settings.
    private func drawAirPlayCard(_ ctx: GraphicsContext, _ session: AirPlaySession, in card: NSRect) {
        ctx.fill(Path(roundedRect: yDown(card), cornerRadius: 12),
                 with: .color(Color(white: 0.72).opacity(0.85)))

        let inner = card.insetBy(dx: 18, dy: 16)
        var ty = inner.maxY
        func line(_ s: String, _ font: NSFont, _ color: NSColor) {
            let bounding = (s as NSString).boundingRect(
                with: CGSize(width: inner.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            ty -= bounding.height
            ctx.draw(Text(s).font(Font(font)).foregroundStyle(Color(nsColor: color)),
                     in: CGRect(x: inner.minX, y: bounds.height - ty - bounding.height,
                                width: inner.width, height: bounding.height + 2))
            ty -= 5
        }

        // Device name, with the AirPlay glyph inline before it — Text concatenation
        // baseline-aligns the symbol against the name for free.
        let nameFont = NSFont.boldSystemFont(ofSize: 20)
        let name = session.receiverName ?? Copy.unknownAirPlayReceiver
        let h = (name as NSString).size(withAttributes: [.font: nameFont]).height
        ty -= h
        let nameText = Text("\(Image(systemName: "airplayvideo")) ").font(.system(size: 18, weight: .semibold))
            + Text(name).font(Font(nameFont))
        ctx.draw(nameText.foregroundStyle(Color(nsColor: .labelColor)),
                 at: CGPoint(x: inner.minX, y: bounds.height - ty - h), anchor: .topLeading)
        ty -= 5
        line(Copy.airplayBody, .systemFont(ofSize: 15), .labelColor)
        line(Copy.airplayFinePrint,
             .systemFont(ofSize: 13), .secondaryLabelColor)

        // Hands off to Control Center's Screen Mirroring menu (Display Settings doesn't
        // know about AirPlay sessions). Pinned to the card's bottom-left — the same rect
        // the hit test answers for.
        let btn = yDown(Self.airplayButtonRect(inCard: card))
        ctx.fill(Path(roundedRect: btn, cornerRadius: 6), with: .color(Color(white: 0.4).opacity(0.9)))
        ctx.draw(Text(Copy.airplayOpenSettings).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white),
                 at: CGPoint(x: btn.midX, y: btn.midY))
    }
}
