import AppKit

/// The always-on seam lights ("Keep the Seams Showing"): a thin static colored bar on each
/// side of every seam, visible at all times, so you always know where the cursor will cross
/// — the arranger's seam story, distilled to 2px and left on overnight.
///
/// Strictly event-driven, per design: the strips are rebuilt only from
/// `AppDelegate.refresh()` (launch, display reconfiguration, arrangement/resolution
/// commits) and the menu toggle. No timers, no draw loops — each strip is a tiny
/// borderless window whose content is a solid layer color; between refreshes the feature
/// costs nothing. A signature check even skips the rebuild when the computed strips are
/// unchanged.
///
/// Outside the arranger the committed macOS *point* layout is the ground truth (no plane
/// reconstruction needed): pairwise `SchematicLayout.seam` on live display bounds gives
/// each seam's crossing interval directly. Colors come from the shared `SeamColorBook`,
/// so a seam wears the same color here and in the arranger.
@MainActor
final class SeamLights {

    private static let defaultsKey = "seamLightsEnabled"

    /// Whether the lights are on. Persisted; setting it applies immediately (the caller
    /// provides fresh displays via `refresh` right after enabling).
    var enabled: Bool = UserDefaults.standard.bool(forKey: SeamLights.defaultsKey) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
            if !enabled { tearDown() }
        }
    }

    private var windows: [NSWindow] = []
    /// Signature of the strips currently on glass (frames + colors), so a refresh that
    /// computes the same strips does nothing at all.
    private var signature = ""

    /// Recompute the strips from the live display layout. The one and only recompute
    /// path — call on launch, display reconfiguration, and arrangement commits.
    func refresh(displays: [DisplaySnapshot]) {
        guard enabled else { return }
        let strips = computeStrips(displays: displays)
        let sig = strips.map { "\($0.frame)|\($0.color)" }.joined(separator: ";")
        guard sig != signature else { return }   // layout unchanged → zero work
        signature = sig
        // Recreate rather than reposition: borderless overlays don't reliably land when
        // `setFrame`-d across a reconfig (see Arranger.rebuild) — and these are
        // tiny windows on a rare, event-driven path.
        tearDown(clearSignature: false)
        windows = strips.map { makeStrip(frame: $0.frame, color: $0.color) }
    }

    private func tearDown(clearSignature: Bool = true) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if clearSignature { signature = "" }
    }

    // MARK: - Geometry

    private struct Strip {
        let frame: NSRect     // Cocoa (y-up) global coords, ready for NSWindow
        let color: NSColor
    }

    /// One 2px strip per seam *side* (each wholly on its own display, echoing how the
    /// arranger draws a bar on each side of the seam), positioned from the live point
    /// layout via the shared engine (same detection, same color book as the arranger).
    private func computeStrips(displays: [DisplaySnapshot]) -> [Strip] {
        let seams = SeamEngine.committedSeams(displays)
        let colors = SeamColorBook.shared.colors(for: seams.map { ($0.a.id, $0.b.id) })

        let thickness: CGFloat = 2
        var strips: [Strip] = []
        for (a, b, s) in seams {
            let color = colors[DisplayGraph.SeamKey(a.id, b.id)] ?? .systemPink
            let len = s.hi - s.lo
            // `line` is the shared coordinate; the crossing interval [lo, hi] runs along
            // it (global CG coords, y-down). One strip hugging each side of the line.
            for side in [-thickness, CGFloat(0)] {
                let cg = s.vertical
                    ? CGRect(x: s.line + side, y: s.lo, width: thickness, height: len)
                    : CGRect(x: s.lo, y: s.line + side, width: len, height: thickness)
                strips.append(Strip(frame: GlobalMap.cocoaRect(fromCG: cg), color: color))
            }
        }
        return strips
    }

    // MARK: - The strip windows

    private func makeStrip(frame: NSRect, color: NSColor) -> NSWindow {
        let w = UnconstrainedWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // Floating: above normal app windows, below the Dock (which may cover a strip
        // where they overlap — acceptable) and well below the arranger overlay
        // (mainMenuWindow−1), so opening the arranger simply covers the lights.
        w.level = .floating
        // All desktop Spaces, pinned in place; deliberately NOT .fullScreenAuxiliary —
        // fullscreen apps (movies, games) stay pristine, per design.
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
        view.layer?.cornerRadius = 1
        w.contentView = view
        w.orderFrontRegardless()
        return w
    }
}

/// A borderless window that keeps the exact frame it's given. NSWindow otherwise clamps a
/// window to its screen's *visible* frame (below the menu bar, above the Dock) unless it
/// sits at a high enough level — and the seam strips must reach the true screen edges where
/// a seam's crossing interval actually runs, menu bar or no.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
