import Foundation

/// One-time migration of persisted settings from the app's previous incarnations
/// into Screen Queen's domain. Each rename — from the "screenmonger" executable, and
/// later from the `com.moxsf.silkscreen` bundle id — repoints `UserDefaults.standard`
/// at a fresh domain, so without this the user's saved layout profiles and size
/// calibrations would silently disappear.
enum PrefsMigration {

    /// The previous app's UserDefaults domain names, most-likely first. Screen Queen
    /// shipped earlier under the `com.moxsf.silkscreen` bundle id, and before that as a
    /// bare SwiftPM executable whose `UserDefaults.standard` domain was the *executable
    /// name* (`screenmonger`); we also try the old intended bundle id in case a later
    /// build wrote there.
    private static let oldDomains = ["com.moxsf.silkscreen", "screenmonger", "com.moxsf.screenmonger"]
    /// Guard so we only copy once (a later legitimate delete shouldn't be undone).
    private static let doneKey = "migratedFromLegacyDomains"
    /// The keys the old app persisted (see `LayoutStore` / `CalibrationStore`).
    private static let keys = ["layoutProfiles", "physicalSizeOverridesMM"]

    /// Copy any old-domain values into the standard domain, once.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)   // mark first, so a partial copy doesn't loop

        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain), !old.isEmpty else { continue }
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
            break   // first non-empty old domain wins
        }
    }
}
