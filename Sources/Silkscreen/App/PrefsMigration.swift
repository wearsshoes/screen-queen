import Foundation

/// One-time migration of persisted settings from the app's previous incarnation
/// (the "screenmonger" executable) into Silkscreen's domain. Renaming the app —
/// and giving it a real bundle id — repoints `UserDefaults.standard` at a fresh
/// domain, so without this the user's saved layout profiles and size calibrations
/// would silently disappear.
enum PrefsMigration {

    /// The previous app's UserDefaults domain names, most-likely first. The old app
    /// ran as a bare SwiftPM executable, so its `UserDefaults.standard` domain was the
    /// *executable name* (`screenmonger`); we also try the intended bundle id in case a
    /// later build wrote there.
    private static let oldDomains = ["screenmonger", "com.moxsf.screenmonger"]
    /// Guard so we only copy once (a later legitimate delete shouldn't be undone).
    private static let doneKey = "migratedFromScreenmonger"
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
