import Foundation

/// Remembers each display's real localized name, keyed by fingerprint, so we can still
/// show it when macOS drops the display from `NSScreen.screens` — which happens while
/// it's a mirrored slave. Whenever a display *is* seen with a proper name, we record it;
/// when it later lacks one, we recall it. Persisted in UserDefaults.
enum NameStore {
    private static let key = "displayNames"

    /// fingerprint → last-seen localized name.
    private static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func name(for fingerprint: String) -> String? { all()[fingerprint] }

    /// Record a display's real name (no-op if unchanged), so it survives mirroring.
    static func remember(_ name: String, for fingerprint: String) {
        guard !name.isEmpty else { return }
        var dict = all()
        guard dict[fingerprint] != name else { return }
        dict[fingerprint] = name
        UserDefaults.standard.set(dict, forKey: key)
    }
}
