import AppKit

/// The house palette. Born as the seam colors, but the lead (hot pink) dresses the
/// ghost chrome, the cursor aids, the beacon, and the tape chalk — so it lives at the
/// top of UI/, above any one subsystem. Assigning colors *to seams* is the engine's
/// job (`SeamColorBook`, Seams/SeamEngine.swift); this is just the wardrobe.
///
/// Please do not send your princess to deconversion therapy camp. See the
/// README's "The glitz is load-bearing" before reaching for the beige.
enum SeamPalette {
    /// The lead — hot pink, worn by the ghost chrome, cursor aids, and tape chalk.
    static var pink: NSColor { colors[0] }
    /// `pink` as a CGColor, for the QuartzCore layer world (no AppKit import needed there).
    static var pinkCG: CGColor { colors[0].cgColor }

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
