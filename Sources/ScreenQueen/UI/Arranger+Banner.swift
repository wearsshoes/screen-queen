import AppKit

/// The top-of-screen countdown banner — the non-modal descendant of the old
/// "Keep this arrangement?" alert. It never steals focus and never blocks: it just
/// sits under the menu bar on *every* screen counting down, because the whole point
/// is surviving the case where some (or all) screens went dark. One row per live
/// countdown (`ArrangerState.countdowns`): the whole-cast resolution revert, and the
/// big-cast feed guard.
final class CountdownBanner: NSVisualEffectView {

    /// Wired by the canvas to `state.resolveCountdown` so a click on any screen's
    /// banner clears them all. `keep` = bless the new state; `!keep` = act right now.
    var onResolve: ((ArrangerState.CountdownKind, _ keep: Bool) -> Void)?

    /// A row button's role, for the ghost's twin lookup (see `GhostTarget`).
    enum Role { case keep, act }

    /// The frame (in this banner's coords) of a live row's button, or nil when that
    /// countdown isn't showing — the ghost's per-canvas twin rect source.
    func buttonRect(kind: ArrangerState.CountdownKind, role: Role) -> CGRect? {
        guard let row = rows[kind], !row.isHidden else { return nil }
        let button = role == .keep ? row.keepButton : row.actButton
        return convert(button.bounds, from: button)
    }

    private var rows: [ArrangerState.CountdownKind: Row] = [:]
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sync to the live countdown table (hides itself when the table is empty).
    func update(_ countdowns: [ArrangerState.CountdownKind: ArrangerState.Countdown]) {
        isHidden = countdowns.isEmpty
        for kind in ArrangerState.CountdownKind.allCases {
            guard let c = countdowns[kind] else { rows[kind]?.isHidden = true; continue }
            let row = ensureRow(kind)
            row.isHidden = false
            row.label.stringValue = Self.message(for: kind, remaining: c.remaining)
        }
    }

    private static func message(for kind: ArrangerState.CountdownKind, remaining: Int) -> String {
        switch kind {
        case .revertModes: return Copy.revertCountdown(remaining)
        case .feedGuard: return Copy.feedGuardCountdown(NSScreen.screens.count, remaining)
        }
    }

    private func ensureRow(_ kind: ArrangerState.CountdownKind) -> Row {
        if let row = rows[kind] { return row }
        let keepTitle: String, actTitle: String
        switch kind {
        case .revertModes: keepTitle = Copy.revertKeep; actTitle = Copy.revertNow
        case .feedGuard: keepTitle = Copy.feedKeep; actTitle = Copy.feedCutNow
        }
        let row = Row(keepTitle: keepTitle, actTitle: actTitle,
                      onKeep: { [weak self] in self?.onResolve?(kind, true) },
                      onAct: { [weak self] in self?.onResolve?(kind, false) })
        rows[kind] = row
        stack.addArrangedSubview(row)
        return row
    }

    /// One countdown's line: message · Keep (pink — she wants you to commit) · act-now.
    private final class Row: NSStackView {
        let label = NSTextField(labelWithString: "")
        let keepButton: NSButton
        let actButton: NSButton
        private let onKeep: () -> Void
        private let onAct: () -> Void

        init(keepTitle: String, actTitle: String,
             onKeep: @escaping () -> Void, onAct: @escaping () -> Void) {
            self.onKeep = onKeep; self.onAct = onAct
            keepButton = NSButton(title: keepTitle, target: nil, action: nil)
            actButton = NSButton(title: actTitle, target: nil, action: nil)
            super.init(frame: .zero)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail

            keepButton.target = self; keepButton.action = #selector(keepTapped)
            keepButton.bezelStyle = .push
            keepButton.controlSize = .regular
            keepButton.bezelColor = NSColor.systemPink.withAlphaComponent(0.85)
            actButton.target = self; actButton.action = #selector(actTapped)
            actButton.bezelStyle = .push
            actButton.controlSize = .regular

            orientation = .horizontal
            alignment = .centerY
            spacing = 12
            setViews([label, keepButton, actButton], in: .center)
        }
        required init?(coder: NSCoder) { fatalError() }

        @objc private func keepTapped() { onKeep() }
        @objc private func actTapped() { onAct() }
    }
}

// MARK: - The canvas's banner hosting

extension Arranger {

    /// Reflect `state.countdowns` in this canvas's banner. Built lazily on the first
    /// countdown (most sessions never see one); called from `refresh()` so every tick
    /// and every resolution reaches every screen.
    func syncBanner() {
        if banner == nil {
            guard !state.countdowns.isEmpty else { return }
            banner = makeBanner()
            needsLayout = true
        }
        banner?.update(state.countdowns)
    }

    private func makeBanner() -> CountdownBanner {
        let b = CountdownBanner()
        b.onResolve = { [weak self] kind, keep in self?.state.resolveCountdown(kind, keep: keep) }
        b.layer?.zPosition = 7   // above the schematic layers, mouse aids included
        b.translatesAutoresizingMaskIntoConstraints = false
        addSubview(b)
        b.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        bannerTop = b.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        bannerTop?.isActive = true   // re-tuned in layout() to clear the menu bar
        return b
    }
}
