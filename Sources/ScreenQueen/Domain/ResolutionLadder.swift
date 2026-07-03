import CoreGraphics

/// Pure resolution-ladder math: given a display's raw mode list (and a few facts about
/// it), decide which "looks like" sizes to surface, in what order, which is default, and
/// each mode's effective PPI. No AppKit, no live system queries, no shared state — the
/// caller supplies the raw modes and flags (from `ModeCatalog` / the display snapshot),
/// so this stays testable and belongs in Domain alongside the rest of the model math.
enum ResolutionLadder {

    /// The modes to offer for a display, mirroring what macOS System Settings surfaces.
    ///
    /// - `all`: every catalog mode for the display.
    /// - `isBuiltin` / `extended`: the built-in normally lists only its clean 2× Retina
    ///   ladder's crisp end; `extended == true` (the per-tile toggle) reveals everything.
    /// - `notched`: a notched built-in also hides the shorter "notchless" variants.
    /// - `current`: the live mode, always kept in the window so the slider/menu land on a
    ///   real entry even when the current mode sits below the crisp band.
    static func modesList(all: [DisplayMode], isBuiltin: Bool, notched: Bool,
                          extended: Bool, current: CGDisplayMode?) -> [DisplayMode] {
        // The full wardrobe is on → everything, unfiltered, for any display.
        guard !extended else { return all }

        // A non-built-in display: surface only modes matching its *native* aspect ratio;
        // stretched/letterboxed resolutions stay behind the "full wardrobe" toggle. The
        // current mode is always kept so the slider/menu land on a real entry.
        if !isBuiltin {
            guard let native = all.nativeMode, native.pixelHeight > 0 else { return all }
            let nativeAspect = Double(native.pixelWidth) / Double(native.pixelHeight)
            func onAspect(_ m: DisplayMode) -> Bool {
                guard m.pixelHeight > 0 else { return false }
                return abs(Double(m.pixelWidth) / Double(m.pixelHeight) - nativeAspect) / nativeAspect <= 0.02
            }
            var kept = all.filter(onAspect)
            if let cur = current.map(ModeKey.init), !kept.contains(where: { $0.key == cur }),
               let curMode = all.first(where: { $0.key == cur }) {
                kept.append(curMode)
            }
            return kept.isEmpty ? all : kept
        }

        // Built-in from here.

        // Standard = clean 2× Retina modes.
        var filtered = all.filter { $0.pixelWidth == 2 * $0.pointWidth }
        // On a notched display also hide the "notchless" (letterboxed, shorter) variants:
        // for each width the notched mode is the tallest, so drop anything shorter than the
        // tallest at that width.
        if notched {
            var tallest: [Int: Int] = [:]
            for m in filtered { tallest[m.pixelWidth] = max(tallest[m.pixelWidth] ?? 0, m.pixelHeight) }
            filtered = filtered.filter { $0.pixelHeight == tallest[$0.pixelWidth] }
        }
        guard !filtered.isEmpty else { return all }

        // The full clean-2× ladder runs from absurdly tiny (640×360) to native, but macOS
        // only surfaces a handful of "looks like" sizes at the crisp (large) end. Match
        // that: take the top of the ladder so the slider/menu don't step through the
        // useless small extremes. The window is *stable* — anchored at the native end, not
        // the moving current mode — so the menu and slider always agree.
        let sorted = byArea(filtered)
        var lo = max(0, sorted.count - 5)   // macOS surfaces ~5 crisp "looks like" sizes
        // Always include the current mode, even if set below the crisp band.
        if let cur = current.map(ModeKey.init), let curIdx = sorted.firstIndex(where: { $0.key == cur }) {
            lo = min(lo, curIdx)
        }
        return Array(sorted[lo...])
    }

    /// The offered modes sorted small → large point area (the ordering the slider and the
    /// ⌘±/0 keys index into).
    static func sortedModes(all: [DisplayMode], isBuiltin: Bool, notched: Bool,
                            extended: Bool, current: CGDisplayMode?) -> [DisplayMode] {
        byArea(modesList(all: all, isBuiltin: isBuiltin, notched: notched, extended: extended, current: current))
    }

    /// The default mode: the largest clean 2× Retina mode (falling back to the largest of
    /// any kind), used by the ⌘0 / ⌘⇧0 reset.
    static func defaultMode(_ modes: [DisplayMode]) -> DisplayMode? {
        let retina = modes.filter { abs($0.pixelWidth - 2 * $0.pointWidth) <= 1 }
        return (retina.isEmpty ? modes : retina).nativeMode
    }

    /// Effective PPI of `mode` given the panel's physical width in millimetres — the
    /// density that governs how big UI looks. nil when the physical size is unknown.
    static func ppi(_ mode: DisplayMode, physicalWidthMM: CGFloat) -> Double? {
        let inches = Double(physicalWidthMM) / 25.4
        guard inches > 0.1 else { return nil }
        return Double(mode.pointWidth) / inches
    }

    private static func byArea(_ modes: [DisplayMode]) -> [DisplayMode] {
        modes.sorted { $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight }
    }
}
