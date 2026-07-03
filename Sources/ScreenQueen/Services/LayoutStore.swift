import CoreGraphics
import Foundation

/// A saved arrangement for a set of displays: each display's position, resolution,
/// and whether it's main — keyed by display fingerprint so it sticks across
/// reconnects. Persisted in UserDefaults.
///
/// Profiles are stored per *display set* (the sorted set of connected
/// fingerprints). On reconnect we apply the largest saved profile whose displays
/// are all present (a superset of the connected set is fine — extra displays are
/// left as-is).
enum LayoutStore {
    private static let table = DefaultsTable<Profile>(key: "layoutProfiles")

    /// One display's saved state.
    struct Entry: Codable, Equatable {
        var name: String = ""   // for readability in the debug view
        var originX: Double
        var originY: Double
        var isMain: Bool
        // Enough to re-find the matching CGDisplayMode on this display.
        var pixelWidth: Int
        var pixelHeight: Int
        var pointWidth: Int
        var pointHeight: Int
    }

    /// A profile: fingerprint → entry, for one display set.
    typealias Profile = [String: Entry]

    /// Canonical key for a set of fingerprints (order-independent).
    private static func setKey(_ fingerprints: [String]) -> String {
        fingerprints.sorted().joined(separator: "|")
    }

    // MARK: - API

    /// Every saved profile, keyed by its set key — for the debug view.
    static func allProfiles() -> [String: Profile] { table.all() }

    /// Build a profile capturing the current layout of `displays`.
    static func profile(from displays: [DisplaySnapshot]) -> Profile {
        var p: Profile = [:]
        for d in displays {
            p[d.fingerprint] = Entry(
                name: d.name,
                originX: Double(d.bounds.minX), originY: Double(d.bounds.minY),
                isMain: d.isMain,
                pixelWidth: Int(d.pixelSize.width), pixelHeight: Int(d.pixelSize.height),
                pointWidth: Int(d.bounds.width), pointHeight: Int(d.bounds.height))
        }
        return p
    }

    /// Save `profile` for its display set.
    static func store(_ profile: Profile) {
        guard !profile.isEmpty else { return }
        table[setKey(Array(profile.keys))] = profile
    }

    /// Forget every saved layout profile.
    static func clearAll() { table.clearAll() }

    /// The best saved profile for the currently-present `fingerprints`: the one with
    /// the most displays whose fingerprints are all present (superset match). nil if
    /// none applies.
    static func bestMatch(for fingerprints: [String]) -> Profile? {
        let present = Set(fingerprints)
        return table.all().values
            .filter { Set($0.keys).isSubset(of: present) }
            .max { $0.count < $1.count }
    }
}
