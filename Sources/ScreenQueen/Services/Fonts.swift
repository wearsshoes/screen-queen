import CoreText
import SwiftUI

enum ScriptFont {
    static let family = "Great Vibes"

    private static var resources: Bundle? {
        let name = "ScreenQueen_ScreenQueen.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for base in bases {
            if let url = base?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        }
        return nil
    }

    static func register() {
        guard let url = resources?.url(forResource: "GreatVibes-Regular", withExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    static func script(size: CGFloat) -> Font { .custom(ScriptFont.family, size: size) }
}
