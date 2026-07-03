import CoreText
import SwiftUI

enum ScriptFont {
    static let family = "Great Vibes"

    /// The SPM resource bundle, located *without* `Bundle.module` — whose generated
    /// accessor for executables checks only the .app root (where a signed bundle can't
    /// legally live) plus an absolute path into the dev build tree, and `fatalError`s
    /// otherwise. That combination shipped a 1.0b1/b2 that launched fine on the dev
    /// machine (the build-tree fallback) and crashed at launch everywhere else. Look in
    /// the app's real Resources directory first (where `package.sh` puts it), then next
    /// to the bare binary (the dev loop), and fail *soft* — she can do the show in the
    /// fallback font.
    private static var resources: Bundle? {
        let name = "ScreenQueen_ScreenQueen.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for base in bases {
            if let url = base?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        }
        return nil
    }

    /// Register the bundled font with the system. Call once, at launch; a second
    /// registration is harmless (CTFontManager de-dupes by URL).
    static func register() {
        // `.copy("Fonts")` preserves the subdirectory inside the resource bundle, so the
        // file lives at Fonts/GreatVibes-Regular.ttf, not the bundle root.
        guard let url = resources?.url(forResource: "GreatVibes-Regular", withExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    /// The script face at `size`.
    static func script(size: CGFloat) -> Font { .custom(ScriptFont.family, size: size) }
}
