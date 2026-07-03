import Foundation

/// A stable drag name for a display, deterministically derived from its hardware
/// fingerprint (vendor/model/serial) — she keeps the same name every time she plugs in,
/// forever, because the fingerprint doesn't change. First name is pure glamour; an
/// ultrawide earns the ", XL" suffix. No RNG, no state — same fingerprint in, same
/// name out, always.
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

    /// A deterministic "First Last[, XL]" drag name for `fingerprint`; the aspect
    /// hint is optional so a bare fingerprint still yields a valid name.
    static func nickname(for fingerprint: String, aspectRatio: Double? = nil) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a
        for b in fingerprint.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let first = firstNames[Int(h % UInt64(firstNames.count))]
        let last = lastNames[Int((h / UInt64(firstNames.count)) % UInt64(lastNames.count))]
        let name = "\(first) \(last)"

        if let ar = aspectRatio, ar >= 2.1 { return "\(name), XL" }
        return name
    }
}
