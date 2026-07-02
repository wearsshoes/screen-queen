import Foundation

/// A stable drag name for a display, deterministically derived from its hardware
/// fingerprint (vendor/model/serial) — she keeps the same name every time she plugs in,
/// forever, because the fingerprint doesn't change. First name is pure glamour; last
/// name winks at what she actually is (built-in, dense, or ultrawide get a suffix; a
/// plain external monitor is just First Last). No RNG, no state — same fingerprint in,
/// same name out, always.
enum Moniker {
    private static let firstNames = [
        "Pixel", "Crystal", "Vanity", "Ivory", "Champagne", "Velvet", "Marquee",
        "Halo", "Gemma", "Electra", "Cassidy", "Diorama", "Foxxy", "Rhinestone",
        "Chiffon", "Lacey", "Peaches", "Sable", "Blanche", "Kitty", "Coco",
        "Delta", "Onyx", "Roxy", "Bijou", "Mercy", "Star", "Chevron", "Amber",
        "Opal", "Scarlet", "Jubilee", "Miracle", "Divinity",
    ]
    private static let lastNames = [
        "Monroe", "DuJour", "LaRue", "St. Clair", "Devereaux", "Vixen", "Delight",
        "Precision", "Vantage", "Supreme", "O'Riley", "Diamond", "Sheen", "Havoc",
        "Couture", "Nightshade", "Radiance", "Fontaine", "Prism", "Voss",
        "Everclear", "Van Cartier", "LaBelle", "Sinclair", "Wildfire", "Glow",
    ]

    /// A deterministic "First Last[, Suffix]" drag name for `fingerprint`. `isBuiltin`
    /// and the density/aspect hints tune the suffix; all are optional so a bare
    /// fingerprint still yields a valid (unsuffixed) name.
    static func nickname(for fingerprint: String, isBuiltin: Bool = false,
                         pixelsPerInch: Double? = nil, aspectRatio: Double? = nil) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a
        for b in fingerprint.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let first = firstNames[Int(h % UInt64(firstNames.count))]
        let last = lastNames[Int((h / UInt64(firstNames.count)) % UInt64(lastNames.count))]
        let name = "\(first) \(last)"

        if let ar = aspectRatio, ar >= 2.1 { return "\(name), XL" }
        return name
    }
}
