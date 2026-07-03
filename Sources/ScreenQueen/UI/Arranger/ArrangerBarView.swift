import SwiftUI

/// Identity of each bar control — tooltip hit-testing and frame reporting key off these.
enum BarControl: Hashable, CaseIterable {
    case feed, reset, undo, slider, scope, done
}

/// Everything the bar renders from. Plain values: the canvas rebuilds the rootView on
/// every refresh/renderChrome pass, so the bar is a pure function of this.
struct BarModel: Equatable {
    var scale: CGFloat = 1        // chromeTileScale — every length/font multiplies by it
    var isGhost = false           // pink chrome on inactive canvases
    var feedEnabled = true
    var scopeAll = false
    var canUndo = false
    var sliderValue = 0.5         // 0…1, detent-snapped upstream
    var sliderEnabled = false
    // House-menu state (the status item is a plain toggle; the menu lives here).
    var seamLightsOn = false
    var wardrobeOn = false
    var version: String?
}

/// The bar's outbound wiring, kept out of the model so Equatable stays derivable.
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
/// `model.scale` — the SwiftUI replacement for the old BarMetrics constraint mutation.
struct ArrangerBarView: View {
    var model: BarModel
    var actions = BarActions()
    /// Reports each control's frame in the bar's own (top-left) coordinate space, for
    /// the ghost-mouse tooltip hit-testing.
    var onControlFrame: (BarControl, CGRect) -> Void = { _, _ in }

    private var k: CGFloat { model.scale }
    private var pink: Color { Color(nsColor: VirtualMouse.pink) }

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
        .coordinateSpace(name: "arrangerBar")
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
        .reportFrame(id, to: onControlFrame)
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
            .strokeBorder(model.isGhost ? pink : Color.white.opacity(0.12),
                          lineWidth: model.isGhost ? 1.5 : 0.5))
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
        .reportFrame(id, to: onControlFrame)
    }

    // MARK: - Shared pieces

    /// The house menu — Backstage Pass, seam lights, wardrobe, debug, version, Quit.
    /// Lives in the bar because the status item is a plain arranger toggle now.
    private var houseMenu: some View {
        Menu {
            Button(Copy.menuSetup, action: actions.showSetup)
            Toggle(Copy.menuSeamLights, isOn: Binding(
                get: { model.seamLightsOn }, set: { _ in actions.toggleSeamLights() }))
            Toggle(Copy.menuShowExtendedResolutions, isOn: Binding(
                get: { model.wardrobeOn }, set: { _ in actions.toggleWardrobe() }))
            Button(Copy.menuDebug, action: actions.showDebug)
            Divider()
            if let version = model.version { Text(version) }
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
        BarSlider(value: model.sliderValue, enabled: model.sliderEnabled,
                  fill: model.isGhost ? pink : Color.accentColor, k: k,
                  onChanged: actions.sliderChanged, onEnded: actions.sliderEnded)
            .frame(minWidth: 60 * k, idealWidth: 144 * k, maxWidth: 144 * k)
            .reportFrame(.slider, to: onControlFrame)
    }

    private var scopeButton: some View {
        Button(action: actions.scope) {
            Image(systemName: model.scopeAll ? "rectangle.stack" : "rectangle")
                .font(.system(size: 15 * k, weight: .semibold))
                .foregroundStyle(iconColor(enabled: true))
                .frame(width: 24 * k, height: 24 * k)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .reportFrame(.scope, to: onControlFrame)
    }

    /// Ghost mode tints only the *icon* — a washed capsule read as a solid pink blob.
    private func iconColor(enabled: Bool) -> Color {
        guard enabled else { return .secondary }
        return model.isGhost ? pink : Color(nsColor: .labelColor)
    }

    private var glyphColor: Color { model.isGhost ? pink : Color(nsColor: .labelColor) }
}

/// The resolution slider, drawn by hand: the stock control dims in non-key windows and
/// only one arranger overlay is key at a time — the same reason the old ArrangerSliderCell
/// existed. Left = larger UI, right = more space (matching macOS). Reports the raw 0…1
/// position; detent snapping/preview lives on the canvas.
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

/// Decoration only — clicks fall through to the canvas.
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
    /// Report this control's frame in the bar's coordinate space whenever it changes.
    func reportFrame(_ control: BarControl,
                     to report: @escaping (BarControl, CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("arrangerBar"))
        } action: { frame in
            report(control, frame)
        }
    }
}
