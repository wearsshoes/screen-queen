import SwiftUI

/// Identity of each bar control — tooltip hit-testing and frame reporting key off these.
enum BarControl: Hashable, CaseIterable {
    case feed, reset, undo, slider, scope, done
}

/// The bar's outbound wiring — plain closures, so the view stays a pure function of
/// the model plus this.
struct BarActions {
    var feed: () -> Void = {}
    var reset: () -> Void = {}
    var undo: () -> Void = {}
    var done: () -> Void = {}
    var scope: () -> Void = {}
    var sliderChanged: (Double) -> Void = { _ in }
    var sliderEnded: () -> Void = {}
    var showSetup: () -> Void = {}
    var showDebug: () -> Void = {}
    var toggleSeamLights: () -> Void = {}
    var toggleWardrobe: () -> Void = {}
    var quit: () -> Void = {}
}

/// The bottom button bar (feed · reset · undo · [resolution slider] · done): Liquid
/// Glass capsules on macOS 26, one HUD box below. All chrome sizes are functions of
/// `scale` — the SwiftUI replacement for the old BarMetrics constraint mutation.
///
/// Observes the shared model directly: the body's reads (feed, undo, scope, pending
/// modes) repaint via Observation. The stage rebuilds the rootView only for the
/// per-stage facts — tile scale, ghost dress, and the commander-owned seam-lights bit.
struct ButtonBarView: View {
    let model: ArrangerModel
    var scale: CGFloat = 1        // chromeTileScale — every length/font multiplies by it
    var isGhost = false           // pink chrome on inactive stages
    var seamLightsOn = false      // commander-owned, not observable — passed in
    var actions = BarActions()
    /// Reports hover per control (SwiftUI owns the hit-testing), for the ghost tooltip.
    var onControlHover: (BarControl, Bool) -> Void = { _, _ in }

    private var k: CGFloat { scale }
    private var pink: Color { ChromeMetrics.ghostPink }

    /// Slider position/enablement from the model: the pending mode (mid-drag, any
    /// stage) wins; else the committed mode. One rule for every stage — the ghosts
    /// mirror a live drag for free.
    private var sliderInfo: (value: Double, enabled: Bool) {
        let modes = model.selectedSliderModes()
        guard modes.count > 1,
              let d = model.selectedID.flatMap({ id in model.displays.first { $0.id == id } })
        else { return (0.5, false) }
        let n = modes.count
        let idx = model.pendingMode(for: d.id).flatMap { modes.firstIndex(of: $0) }
            ?? model.currentModeIndex(for: d, in: modes) ?? (n - 1) / 2
        return (Double(idx) / Double(n - 1), true)
    }

    var body: some View {
        // No width cap here: `layoutBar` clamps the hosting frame to `barWidthCap`,
        // which makes SwiftUI propose the capped width and the slider compress.
        Group {
            if #available(macOS 26.0, *) {
                glassBar
            } else {
                hudBar
            }
        }
    }

    // MARK: - macOS 26: separate glass capsules that merge when close

    @available(macOS 26.0, *)
    private var glassBar: some View {
        GlassEffectContainer(spacing: 14 * k) {
            HStack(spacing: 22 * k) {
                circleButton(.feed, symbol: model.feedEnabled ? "figure.run" : "figure.stand",
                             action: actions.feed)
                circleButton(.reset, symbol: "arrow.counterclockwise", enabled: model.canUndo,
                             shortcut: KeyboardShortcut(.delete, modifiers: .command),
                             action: actions.reset)
                circleButton(.undo, symbol: "arrow.uturn.backward", enabled: model.canUndo,
                             shortcut: KeyboardShortcut("z", modifiers: .command),
                             action: actions.undo)
                sliderPill
                circleButton(.done, symbol: "checkmark", prominent: true,
                             shortcut: .defaultAction,
                             action: actions.done)
                houseMenu
                    .frame(width: 56 * k, height: 56 * k)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }

    /// A chromeless icon button whose glass capsule *is* the surface; `.interactive()`
    /// supplies the hover/press response the old HoverGlassView hand-rolled.
    @available(macOS 26.0, *)
    private func circleButton(_ id: BarControl, symbol: String, enabled: Bool = true,
                              prominent: Bool = false, shortcut: KeyboardShortcut? = nil,
                              action: @escaping () -> Void) -> some View {
        let d = 56 * k
        // A lighter accent so the clear glass stays see-through on Done.
        let doneTint = Color(nsColor: (NSColor.systemPink.blended(withFraction: 0.6, of: .white)
            ?? .systemPink).withAlphaComponent(0.4))
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: enabled))
                .frame(width: d, height: d)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(OptionalShortcut(shortcut: shortcut))
        .glassEffect(prominent ? .regular.tint(doneTint).interactive() : .regular.interactive(),
                     in: Circle())
        .reportHover(id, to: onControlHover)
    }

    /// The glass pill hosting the resolution slider, flanked by "A" / "a" end glyphs
    /// and the one/all scope toggle.
    @available(macOS 26.0, *)
    private var sliderPill: some View {
        HStack(spacing: 8 * k) {
            Text("A").font(.system(size: 20 * k, weight: .bold)).foregroundStyle(glyphColor)
            slider
            Text("a").font(.system(size: 14 * k)).foregroundStyle(glyphColor)
            scopeButton.padding(.leading, 6)
        }
        .padding(.horizontal, 20 * k)
        .frame(height: 56 * k)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    // MARK: - Pre-26: one HUD box

    private var hudBar: some View {
        HStack(spacing: 12 * k) {
            plainButton(.feed, symbol: model.feedEnabled ? "figure.run" : "figure.stand",
                        action: actions.feed)
            plainButton(.reset, symbol: "arrow.counterclockwise", enabled: model.canUndo,
                        shortcut: KeyboardShortcut(.delete, modifiers: .command),
                        action: actions.reset)
            plainButton(.undo, symbol: "arrow.uturn.backward", enabled: model.canUndo,
                        shortcut: KeyboardShortcut("z", modifiers: .command),
                        action: actions.undo)
            slider
            scopeButton
            plainButton(.done, symbol: "checkmark", shortcut: .defaultAction,
                        action: actions.done)
            houseMenu
                .frame(width: 44 * k, height: 44 * k)
        }
        .padding(.vertical, 12 * k)
        .padding(.horizontal, 16 * k)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22 * k, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22 * k, style: .continuous)
            .strokeBorder(isGhost ? pink : Color.white.opacity(0.12),
                          lineWidth: isGhost ? 1.5 : 0.5))
    }

    private func plainButton(_ id: BarControl, symbol: String, enabled: Bool = true,
                             shortcut: KeyboardShortcut? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: enabled))
                .frame(width: 44 * k, height: 44 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(OptionalShortcut(shortcut: shortcut))
        .reportHover(id, to: onControlHover)
    }

    // MARK: - Shared pieces

    /// The house menu — Backstage Pass, seam lights, wardrobe, debug, version, Quit.
    /// Lives in the bar because the status item is a plain arranger toggle now.
    private var houseMenu: some View {
        Menu {
            Button(Copy.menuSetup, action: actions.showSetup)
            Toggle(Copy.menuSeamLights, isOn: Binding(
                get: { seamLightsOn }, set: { _ in actions.toggleSeamLights() }))
            Toggle(Copy.menuShowExtendedResolutions, isOn: Binding(
                get: { model.extendedBuiltinModes }, set: { _ in actions.toggleWardrobe() }))
            Button(Copy.menuDebug, action: actions.showDebug)
            Divider()
            if let version = Self.versionLine { Text(version) }
            Button(Copy.menuQuit, action: actions.quit)
        } label: {
            Image(systemName: "crown")
                .font(.system(size: 20 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: true))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var slider: some View {
        BarSlider(value: sliderInfo.value, enabled: sliderInfo.enabled,
                  fill: isGhost ? pink : Color.accentColor, k: k,
                  onChanged: actions.sliderChanged, onEnded: actions.sliderEnded)
            .frame(minWidth: 60 * k, idealWidth: 144 * k, maxWidth: 144 * k)
            .reportHover(.slider, to: onControlHover)
    }

    private var scopeButton: some View {
        Button(action: actions.scope) {
            Image(systemName: model.sliderScope == .all ? "rectangle.stack" : "rectangle")
                .font(.system(size: 15 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: true))
                .frame(width: 24 * k, height: 24 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reportHover(.scope, to: onControlHover)
    }

    /// Ghost mode tints only the *icon* — a washed capsule read as a solid pink blob.
    private func iconColor(enabled: Bool) -> Color {
        guard enabled else { return .secondary }
        return isGhost ? pink : Color.primary
    }

    private var glyphColor: Color { isGhost ? pink : Color.primary }

    /// Version line for the house menu (nil for the bare dev binary — no Info.plist).
    static let versionLine: String? = {
        guard let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return "Screen Queen \(v) (\(b))"
    }()
}

/// The resolution slider, drawn by hand: the stock control dims in non-key windows and
/// only one arranger overlay is key at a time — the same reason the old ArrangerSliderCell
/// existed. Left = larger UI, right = more space (matching macOS). Reports the raw 0…1
/// position; detent snapping/preview lives on the stage.
private struct BarSlider: View {
    var value: Double
    var enabled: Bool
    var fill: Color
    var k: CGFloat
    var onChanged: (Double) -> Void
    var onEnded: () -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knob = 20 * k
            let trackH = 4 * k
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                    .frame(height: trackH)
                Capsule().fill(fill)
                    .frame(width: max(0, CGFloat(value) * (w - knob) + knob / 2), height: trackH)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5 * k, y: 0.5 * k)
                    .frame(width: knob, height: knob)
                    .offset(x: CGFloat(value) * (w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled, w > knob else { return }
                    let raw = (g.location.x - knob / 2) / (w - knob)
                    onChanged(Double(min(max(raw, 0), 1)))
                }
                .onEnded { _ in
                    guard enabled else { return }
                    onEnded()
                })
        }
        .frame(height: 20 * k)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// The instruction line under the bar (see `Copy.footer`), font-scaled with it.
struct FooterView: View {
    var scale: CGFloat
    var body: some View {
        Text(Copy.footer)
            .font(.system(size: (11 * scale).rounded()))   // whole-point hints crispest
            .foregroundStyle(.tertiary)
            .fixedSize()
    }
}

/// Decoration only — clicks fall through to the stage.
final class FooterHost: NSHostingView<FooterView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `.keyboardShortcut` can't take an optional; this applies one when present.
private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?
    func body(content: Content) -> some View {
        if let shortcut { content.keyboardShortcut(shortcut) } else { content }
    }
}

private extension View {
    /// Report this control's hover state, tagged with its identity.
    func reportHover(_ control: BarControl,
                     to report: @escaping (BarControl, Bool) -> Void) -> some View {
        onHover { report(control, $0) }
    }
}

// MARK: - Stage plumbing (actions, placement)

/// The bottom button bar's stage-side wiring: the NSHostingView island, the action
/// closures, and frame placement. The bar's look lives in ButtonBarView (SwiftUI);
/// its shared inputs arrive by Observation — the rootView is rebuilt only when the
/// per-stage facts (tile scale, ghost dress, seam-lights bit) change.
extension Stage {

    func setupButtonBar() {
        let host = NSHostingView(rootView: makeBarView())
        host.translatesAutoresizingMaskIntoConstraints = true
        addSubview(host)
        barHost = host

        // The instruction line under the bar — a sibling island, positioned + scaled
        // in `layoutFooter`.
        let footer = FooterHost(rootView: FooterView(scale: 1))
        addSubview(footer)
        footerHost = footer
    }

    /// Re-dress the bar with the per-stage facts. `scale` sticks when given
    /// (renderChrome passes its pass's chromeTileScale; other callers reuse the last).
    func updateBar(scale: CGFloat? = nil) {
        if let scale { barScale = scale }
        barHost?.rootView = makeBarView()
    }

    private func makeBarView() -> ButtonBarView {
        ButtonBarView(model: model, scale: barScale, isGhost: isGhost,
                      seamLightsOn: model.commander?.seamLightsOn ?? false,
                      actions: barActions()) { [weak self] control, hovering in
            guard let self else { return }
            if hovering { self.hoveredBarControl = control }
            else if self.hoveredBarControl == control { self.hoveredBarControl = nil }
        }
    }

    private func barActions() -> BarActions {
        BarActions(
            feed: { [weak self] in
                guard let self else { return }
                self.model.onToggleFeed?(!self.model.feedEnabled)
            },
            reset: { [weak self] in self?.model.commander?.resetToBaseline() },
            undo: { [weak self] in self?.model.undo() },
            done: { [weak self] in self?.commander?.dismissArranger() },
            scope: { [weak self] in
                guard let self else { return }
                self.model.sliderScope = self.model.sliderScope == .one ? .all : .one
                self.model.notify()   // refresh every stage so the icon/tooltip update everywhere
            },
            sliderChanged: { [weak self] raw in self?.model.sliderChanged(raw) },
            sliderEnded: { [weak self] in self?.model.sliderEnded() },
            showSetup: { [weak self] in self?.commander?.showSetup() },
            showDebug: { [weak self] in self?.commander?.showDebug() },
            toggleSeamLights: { [weak self] in
                self?.commander?.toggleSeamLights()
                self?.model.notify()   // re-render the checkmark on every stage
            },
            toggleWardrobe: { [weak self] in
                guard let self else { return }
                self.model.extendedBuiltinModes.toggle()
                self.model.notify()   // re-derive the slider/menu mode lists everywhere
            },
            quit: { NSApp.terminate(nil) })
    }

    /// The fun copy per control — the single source (no native `.toolTip`; it would pop
    /// on the hovered screen only, doubling up).
    func tooltipText(for control: BarControl) -> String? {
        switch control {
        case .feed:   return model.feedEnabled ? Copy.feedOnTooltip : Copy.feedOffTooltip
        case .reset:  return Copy.resetTooltip
        case .undo:   return Copy.undoTooltip
        case .slider: return Copy.sliderTooltip
        case .scope:  return model.sliderScope == .all ? Copy.scopeAllTooltip : Copy.scopeOneTooltip
        case .done:   return Copy.doneTooltip
        }
    }

    func barControlEnabled(_ control: BarControl) -> Bool {
        switch control {
        case .reset, .undo: return model.canUndo
        case .slider:       return model.selectedSliderModes().count > 1
        case .feed, .scope, .done: return true
        }
    }

    /// Place the bar through `chromeViewRect` — the same positioning code as the granny
    /// viewer. Width capped so the bar never overflows a narrow screen: the clamped
    /// hosting frame makes SwiftUI propose the capped width and the slider compresses,
    /// identically on every stage.
    func layoutBar(in t: Transform) {
        guard let host = barHost else { return }
        var size = host.fittingSize
        if model.minScreenExtent.width > 0 {
            size.width = min(size.width, Self.barWidthCap(minScreenWidth: model.minScreenExtent.width))
        }
        host.frame = chromeViewRect(finalSize: size,
                                    centreOffsetInches: barCentreOffsetInches, in: t)
    }

    /// The bar centre's offset from the screen centre, in **plane inches** (map-relative,
    /// like the granny viewer — drifts/rescales with the minimap). +y is down.
    private var barCentreOffsetInches: CGPoint { CGPoint(x: 0, y: 10) }

    /// Position the footer under this stage's own bar, font scaled with it (text laid
    /// out at the target point size — crisp, not a layer-scaled bitmap). Called from
    /// renderChrome right after `layoutBar`, so the bar frame is settled.
    func layoutFooter(scale s: CGFloat) {
        guard let bar = barHost, let footer = footerHost else { return }
        if footer.rootView.scale != s { footer.rootView = FooterView(scale: s) }
        let size = footer.fittingSize
        footer.frame = CGRect(x: pixelSnap(bar.frame.midX - size.width / 2),
                              y: pixelSnap(bar.frame.maxY + 8 * s),
                              width: size.width, height: size.height)
    }

}
