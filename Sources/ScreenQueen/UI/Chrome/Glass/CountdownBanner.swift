import SwiftUI

/// The top-of-screen countdown banner — the non-modal descendant of the old "Keep this
/// arrangement?" alert. It never steals focus and sits under the menu bar on *every*
/// screen, because the whole point is surviving the case where some screens went dark.
/// One row per live countdown (`ArrangerState.countdowns`).
struct CountdownBannerView: View {
    struct Row {
        let message: String, keepTitle: String, actTitle: String
    }
    /// Observes the state directly (the `countdowns` read in `body` tracks the ticks).
    /// The screen count is a model input, frozen at stage creation — a reconfig
    /// rebuilds every stage anyway.
    let state: ArrangerState
    let screenCount: Int

    var body: some View {
        VStack(spacing: 8) {
            ForEach(ArrangerState.CountdownKind.allCases, id: \.self) { kind in
                if let c = state.countdowns[kind] {
                    row(kind, remaining: c.remaining)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private func copyRow(_ kind: ArrangerState.CountdownKind, remaining: Int) -> Row {
        switch kind {
        case .revertModes:
            Row(message: Copy.revertCountdown(remaining),
                keepTitle: Copy.revertKeep, actTitle: Copy.revertNow)
        case .feedGuard:
            Row(message: Copy.feedGuardCountdown(screenCount, remaining),
                keepTitle: Copy.feedKeep, actTitle: Copy.feedCutNow)
        }
    }

    /// One countdown's line: message · Keep (pink — she wants you to commit) · act-now.
    private func row(_ kind: ArrangerState.CountdownKind, remaining: Int) -> some View {
        let c = copyRow(kind, remaining: remaining)
        return HStack(spacing: 12) {
            Text(c.message)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Button(c.keepTitle) { state.resolveCountdown(kind, keep: true) }
                .buttonStyle(.borderedProminent)
                .tint(Color.pink.opacity(0.85))
            Button(c.actTitle) { state.resolveCountdown(kind, keep: false) }
        }
    }
}

// MARK: - The stage's banner hosting

extension Stage {

    /// Reflect `state.countdowns` in this stage's banner. Built lazily on the first
    /// countdown (most sessions never see one); content then updates itself via
    /// Observation — this only manages existence and visibility.
    func syncBanner() {
        if banner == nil {
            guard !state.countdowns.isEmpty else { return }
            banner = makeBanner()
            needsLayout = true
        }
        banner?.isHidden = state.countdowns.isEmpty
    }

    private func makeBanner() -> NSHostingView<CountdownBannerView> {
        let b = NSHostingView(rootView: CountdownBannerView(state: state,
                                                            screenCount: NSScreen.screens.count))
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
