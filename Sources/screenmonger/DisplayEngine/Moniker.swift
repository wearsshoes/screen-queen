import Foundation

/// A stable, memorable nickname derived from a display's fingerprint — a temporary
/// stand-in until the user can assign real custom names, and a friendlier handle
/// than a raw vendor-model-serial string when referring to a monitor.
enum Moniker {
    private static let adjectives = [
        "amber", "azure", "brave", "calm", "crisp", "dapper", "eager", "fuzzy",
        "gentle", "happy", "ivory", "jolly", "keen", "lucky", "merry", "nimble",
        "olive", "plucky", "quiet", "rusty", "sunny", "teal", "umber", "vivid",
        "witty", "zesty", "bold", "cozy", "dusk", "fern",
    ]
    private static let nouns = [
        "otter", "falcon", "maple", "comet", "pixel", "harbor", "willow", "ember",
        "badger", "cobra", "delta", "finch", "grove", "heron", "iris", "jasper",
        "koi", "lynx", "moth", "newt", "onyx", "puma", "quartz", "raven",
        "sparrow", "tulip", "viper", "wren", "yak", "zebra",
    ]

    /// A deterministic "adjective-noun" nickname for `fingerprint`.
    static func nickname(for fingerprint: String) -> String {
        var h: UInt64 = 1469598103934665603   // FNV-1a
        for b in fingerprint.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let a = adjectives[Int(h % UInt64(adjectives.count))]
        let n = nouns[Int((h / UInt64(adjectives.count)) % UInt64(nouns.count))]
        return "\(a)-\(n)"
    }
}
