import AppKit

/// The seam palette. `DisplayGraph` assigns each seam an index (pure edge-coloring);
/// the colors are a presentation choice and live here — shared by the arranger and the
/// always-on seam lights, with no dependency on the arranger's editing state.
///
/// Please do not send your princess to deconversion therapy camp. See the
/// README's "The glitz is load-bearing" before reaching for the beige.
enum SeamPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.41, blue: 0.71, alpha: 1),  // hot pink (the lead)
        NSColor(srgbRed: 0.64, green: 0.24, blue: 0.95, alpha: 1),  // violet
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.20, alpha: 1),  // gold
        NSColor(srgbRed: 0.25, green: 0.85, blue: 0.95, alpha: 1),  // electric cyan
        NSColor(srgbRed: 0.72, green: 0.45, blue: 1.00, alpha: 1),  // lavender
        NSColor(srgbRed: 1.00, green: 0.45, blue: 0.35, alpha: 1),  // coral
        NSColor(srgbRed: 0.45, green: 0.95, blue: 0.65, alpha: 1),  // mint (range, honey)
        NSColor(srgbRed: 0.95, green: 0.20, blue: 0.30, alpha: 1),  // classic red lip
    ]
}

/// The app's one seam→color assignment, shared by every consumer so a seam wears the
/// same color everywhere. Feeds the last assignment back into the edge-coloring, so a
/// surviving seam keeps its color across rebuilds.
@MainActor
final class SeamColorBook {
    static let shared = SeamColorBook()

    private var last: [DisplayGraph.SeamKey: Int] = [:]

    /// The color for each seam (unordered display pair), stable across calls.
    func colors(for pairs: [(CGDirectDisplayID, CGDirectDisplayID)]) -> [DisplayGraph.SeamKey: NSColor] {
        let indices = DisplayGraph.seamColorIndices(pairs, previous: last)
        last = indices   // only surviving seams (the result drops vanished ones)
        return indices.mapValues { SeamPalette.colors[$0 % SeamPalette.colors.count] }
    }
}
