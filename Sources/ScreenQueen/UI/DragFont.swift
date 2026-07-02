import AppKit

/// The marquee typeface: Great Vibes (a script/cursive face, OFL-licensed, bundled in
/// `Fonts/`) — because a drag name in San Francisco is not a drag name. Used for tile
/// headlines and card titles; the technical readouts (resolution, ppi, tooltips) stay in
/// the system font on purpose, for neutral legibility at small sizes. Single static
/// weight — no weight axis, no separate italic (a script face doesn't need one).
enum DragFont {
    private static let family = "Great Vibes"
    /// The PostScript name read straight from the registered font file, kept as a backup
    /// lookup key in case the human-readable family name ever fails to resolve.
    private static var registeredPostScriptName: String?

    /// Register the bundled font with the system. Call once, at launch; a second
    /// registration is harmless (CTFontManager de-dupes by URL).
    static func register() {
        // `.copy("Fonts")` preserves the subdirectory inside the resource bundle, so the
        // file lives at Fonts/GreatVibes-Regular.ttf, not the bundle root.
        guard let url = Bundle.module.url(forResource: "GreatVibes-Regular", withExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if let provider = CGDataProvider(url: url as CFURL), let cgFont = CGFont(provider) {
            registeredPostScriptName = cgFont.postScriptName as String?
        }
    }

    /// The script face at `size`. Falls back to a system italic if the family somehow
    /// didn't register (e.g. running before `register()`).
    static func script(size: CGFloat) -> NSFont {
        if let font = NSFont(name: family, size: size) { return font }
        if let ps = registeredPostScriptName, let font = NSFont(name: ps, size: size) { return font }
        return NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }
}
