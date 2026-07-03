import SwiftUI

/// The right-hand column overlay: read-only cards for mirrored displays (name /
/// resolution / what they mirror, with an un-mirror button) and a macOS-managed
/// AirPlay session. Screen-anchored UI above the schematic, unrelated to the
/// physical plane.
struct MirrorColumnContent {
    struct Card: Identifiable {
        let id: CGDirectDisplayID
        let nickname: String
        let name: String
        let resolution: String
        let detail: String?
        let mirrors: String
        /// From the mirrored screen's aspect, clamped so the text still fits.
        let height: CGFloat
    }
    var cards: [Card] = []
    var airplayName: String?
}

struct MirrorColumnView: View {
    var content: MirrorColumnContent
    var unmirror: (CGDirectDisplayID) -> Void = { _ in }
    var openAirPlaySettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !content.cards.isEmpty {
                header(Copy.mirroredHeader)
                ForEach(content.cards) { mirrorCard($0) }
            }
            if let name = content.airplayName {
                header(Copy.airplayHeader)
                airplayCard(name)
            }
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func mirrorCard(_ card: MirrorColumnContent.Card) -> some View {
        // The glow blend (pink toward white) stays NSColor-sourced: Color.mix is macOS 15+.
        let nameGlow = Color(nsColor: NSColor.systemPink.blended(withFraction: 0.55, of: .white) ?? .white)
        let dim = Color.white.opacity(0.7)
        return VStack(alignment: .leading, spacing: 5) {
            Text(card.nickname).font(.script(size: 30)).foregroundStyle(.pink)
                .shadow(color: nameGlow, radius: 6)
            Text(card.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(card.resolution).font(.system(size: 15)).foregroundStyle(.white)
            if let detail = card.detail {
                Text(detail).font(.system(size: 15)).foregroundStyle(dim)
            }
            Text(card.mirrors).font(.system(size: 15)).foregroundStyle(dim)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, minHeight: card.height, alignment: .topLeading)
        // Dark card so the drag name's glow reads as a glow, not a smudge.
        .background(Color(white: 0.12).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button { unmirror(card.id) } label: {
                Text("✕").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(white: 0.4).opacity(0.9)))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    /// A read-only card for a macOS-managed AirPlay *visual* session — it can have no
    /// `CGDirectDisplay` ("Window or App" mode), hence a card and not a plane tile. We
    /// can detect it but not cancel it, so the action hands off to system settings.
    private func airplayCard(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // The AirPlay glyph inline before the name — Text concatenation
            // baseline-aligns the symbol against the name for free.
            (Text("\(Image(systemName: "airplayvideo")) ").font(.system(size: 18, weight: .semibold))
                + Text(name).font(.system(size: 20, weight: .bold)))
                .foregroundStyle(Color.primary)
            Text(Copy.airplayBody).font(.system(size: 15)).foregroundStyle(Color.primary)
            Text(Copy.airplayFinePrint).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Hands off to Control Center's Screen Mirroring menu (Display Settings
            // doesn't know about AirPlay sessions).
            Button(action: openAirPlaySettings) {
                Text(Copy.airplayOpenSettings).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 168, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.4).opacity(0.9)))
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Color(white: 0.72).opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }
}

final class MirrorColumnHost: NSHostingView<MirrorColumnView> {}

// MARK: - Stage plumbing

extension Stage {

    /// Width of the right-hand column overlay (0 when it holds nothing).
    var mirrorColumnWidth: CGFloat {
        mirroredDisplays.isEmpty && airplaySession == nil ? 0 : 360
    }

    /// Rebuild + place the column against the right edge (refresh path); hidden when
    /// it holds nothing.
    func layoutMirrorColumn() {
        let mirrored = mirroredDisplays
        guard !mirrored.isEmpty || airplaySession != nil else {
            mirrorColumn?.isHidden = true
            return
        }
        let colW = mirrorColumnWidth
        let pad: CGFloat = 18
        let cardW = colW - pad * 2       // fixed width; height follows each screen's aspect
        var content = MirrorColumnContent()
        for d in mirrored {
            let sz = pointSize(d)
            let aspect = sz.height > 0 ? sz.width / sz.height : 16.0 / 9
            let effPPI = d.diagonalInches > 0 && sz.width > 0
                ? Double(sz.width) / (Double(d.physicalSizeMM.width) / 25.4) : nil
            let diag = d.diagonalInches > 0 ? String(format: "%.0f″ · ", d.diagonalInches) : ""
            let detail = effPPI.map { diag + String(format: "%.0f ppi", $0) }
                ?? (diag.isEmpty ? nil : String(diag.dropLast(3)))
            let hidpi = Int(d.pixelSize.width) > Int(sz.width) ? " HiDPI" : ""
            let master = displays.first { $0.id == d.mirrorMaster }?.name ?? Copy.unknownDisplayName
            content.cards.append(.init(
                id: d.id, nickname: d.nickname, name: d.name,
                resolution: "\(Int(sz.width))×\(Int(sz.height))\(hidpi)",
                detail: detail, mirrors: Copy.mirrorsLine(master),
                height: min(max(cardW / max(aspect, 0.1), 120), 260)))
        }
        if airplaySession != nil {
            content.airplayName = airplaySession?.receiverName ?? Copy.unknownAirPlayReceiver
        }
        let host = ensureMirrorColumn()
        host.rootView = MirrorColumnView(
            content: content,
            unmirror: { [weak self] id in self?.commander?.unmirror(id) },
            openAirPlaySettings: { [weak self] in self?.commander?.openAirPlaySettings() })
        host.frame = NSRect(x: bounds.width - colW + pad, y: outerPadding,
                            width: cardW, height: host.fittingSize.height)
        host.isHidden = false
    }

    private func ensureMirrorColumn() -> MirrorColumnHost {
        if let c = mirrorColumn { return c }
        let c = MirrorColumnHost(rootView: MirrorColumnView(content: MirrorColumnContent()))
        addSubview(c)
        mirrorColumn = c
        return c
    }
}
