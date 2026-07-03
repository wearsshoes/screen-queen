import SwiftUI

/// The top-of-screen countdown banner — the non-modal descendant of the old "Keep this
/// arrangement?" alert. It never steals focus and sits under the menu bar on *every*
/// screen, because the whole point is surviving the case where some screens went dark.
/// One row per live countdown (`ArrangerState.countdowns`).
struct CountdownBannerView: View {
    let countdowns: [ArrangerState.CountdownKind: (remaining: Int, keepTitle: String, actTitle: String)]
    let resolve: (ArrangerState.CountdownKind, _ keep: Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(ArrangerState.CountdownKind.allCases, id: \.self) { kind in
                if let c = countdowns[kind] {
                    row(kind, c)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    /// One countdown's line: message · Keep (pink — she wants you to commit) · act-now.
    private func row(_ kind: ArrangerState.CountdownKind,
                     _ c: (remaining: Int, keepTitle: String, actTitle: String)) -> some View {
        HStack(spacing: 12) {
            Text(Self.message(for: kind, remaining: c.remaining))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Button(c.keepTitle) { resolve(kind, true) }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: .systemPink).opacity(0.85))
            Button(c.actTitle) { resolve(kind, false) }
        }
    }

    static func message(for kind: ArrangerState.CountdownKind, remaining: Int) -> String {
        switch kind {
        case .revertModes: return Copy.revertCountdown(remaining)
        case .feedGuard: return Copy.feedGuardCountdown(NSScreen.screens.count, remaining)
        }
    }
}

// MARK: - The canvas's banner hosting

extension Arranger {

    /// Reflect `state.countdowns` in this canvas's banner. Built lazily on the first
    /// countdown (most sessions never see one); called from `refresh()`.
    func syncBanner() {
        if banner == nil {
            guard !state.countdowns.isEmpty else { return }
            banner = makeBanner()
            needsLayout = true
        }
        banner?.rootView = bannerView()
        banner?.isHidden = state.countdowns.isEmpty
    }

    private func bannerView() -> CountdownBannerView {
        var rows: [ArrangerState.CountdownKind: (remaining: Int, keepTitle: String, actTitle: String)] = [:]
        for (kind, c) in state.countdowns {
            switch kind {
            case .revertModes: rows[kind] = (c.remaining, Copy.revertKeep, Copy.revertNow)
            case .feedGuard: rows[kind] = (c.remaining, Copy.feedKeep, Copy.feedCutNow)
            }
        }
        return CountdownBannerView(countdowns: rows) { [weak self] kind, keep in
            self?.state.resolveCountdown(kind, keep: keep)
        }
    }

    private func makeBanner() -> NSHostingView<CountdownBannerView> {
        let b = NSHostingView(rootView: bannerView())
        b.wantsLayer = true
        b.layer?.zPosition = 5   // above the schematic layers, below the ghost mouse (z6)
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        b.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        bannerTop = b.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        bannerTop?.isActive = true   // re-tuned in layout() to clear the menu bar
        return b
    }
}
