import SwiftUI

/// The right-hand column overlay: read-only cards for mirrored displays (name /
/// resolution / what they mirror, with an un-mirror button) and a macOS-managed
/// AirPlay session. Screen-anchored UI above the schematic, unrelated to the
/// physical plane.
///
/// Observes the shared model directly: the body's reads (mirrored displays, AirPlay
/// session, stat lines) repaint via Observation, and the host self-sizes through
/// Auto Layout. The stage only creates the host and toggles its visibility.
struct MirrorColumnView: View {
    let model: ArrangerModel

    /// Fixed card width: the column's 360 minus 18 breathing room each side.
    static let cardWidth: CGFloat = 324

    var body: some View {
        let mirrored = model.mirroredDisplays
        VStack(alignment: .leading, spacing: 16) {
            if !mirrored.isEmpty {
                header(Copy.mirroredHeader)
                ForEach(mirrored, id: \.id) { mirrorCard($0) }
            }
            if model.airplaySession != nil {
                header(Copy.airplayHeader)
                airplayCard(model.airplaySession?.receiverName ?? Copy.unknownAirPlayReceiver)
            }
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func mirrorCard(_ d: DisplaySnapshot) -> some View {
        let sz = model.pointSize(d)
        let aspect = sz.height > 0 ? sz.width / sz.height : 16.0 / 9
        let stats = model.statLines(for: d)
        let master = model.displays.first { $0.id == d.mirrorMaster }?.name ?? Copy.unknownDisplayName
        // From the mirrored screen's aspect, clamped so the text still fits.
        let height = min(max(Self.cardWidth / max(aspect, 0.1), 120), 260)
        // The glow blend (pink toward white) stays NSColor-sourced: Color.mix is macOS 15+.
        let nameGlow = Color(nsColor: NSColor.systemPink.blended(withFraction: 0.55, of: .white) ?? .white)
        let dim = Color.white.opacity(0.7)
        return VStack(alignment: .leading, spacing: 5) {
            Text(d.nickname).font(.script(size: 30)).foregroundStyle(.pink)
                .shadow(color: nameGlow, radius: 6)
            Text(d.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(stats.resolution).font(.system(size: 15)).foregroundStyle(.white)
            Text(stats.detail).font(.system(size: 15)).foregroundStyle(dim)
            Text(Copy.mirrorsLine(master)).font(.system(size: 15)).foregroundStyle(dim)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        // Dark card so the drag name's glow reads as a glow, not a smudge.
        .background(Color(white: 0.12).opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button { model.commander?.unmirror(d.id) } label: {
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
            Button { model.commander?.openAirPlaySettings() } label: {
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
        model.mirroredDisplays.isEmpty && model.airplaySession == nil ? 0 : 360
    }

    /// Show/hide the column (content and height are Observation's job now).
    func layoutMirrorColumn() {
        guard mirrorColumnWidth > 0 else {
            mirrorColumn?.isHidden = true
            return
        }
        ensureMirrorColumn().isHidden = false
    }

    private func ensureMirrorColumn() -> MirrorColumnHost {
        if let c = mirrorColumn { return c }
        let c = MirrorColumnHost(rootView: MirrorColumnView(model: model))
        c.translatesAutoresizingMaskIntoConstraints = false
        addSubview(c)
        // Top-right pin; height rides the SwiftUI content's intrinsic size.
        NSLayoutConstraint.activate([
            c.topAnchor.constraint(equalTo: topAnchor, constant: outerPadding),
            c.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            c.widthAnchor.constraint(equalToConstant: MirrorColumnView.cardWidth),
        ])
        mirrorColumn = c
        return c
    }
}
