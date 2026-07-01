import Foundation

/// One-time migration of persisted settings from the app's previous bundle id
/// (`com.moxsf.screenmonger`, when the app was named "screenmonger") into the
/// current standard domain. Renaming the bundle repoints `UserDefaults.standard`
/// at a fresh domain, so without this the user's saved layout profiles and size
/// calibrations would silently disappear.
enum PrefsMigration {

    /// The previous app's UserDefaults suite name.
    private static let oldDomain = "com.moxsf.screenmonger"
    /// Guard so we only copy once (a later legitimate delete shouldn't be undone).
    private static let doneKey = "migratedFromScreenmonger"
    /// The keys the old app persisted (see `LayoutStore` / `CalibrationStore`).
    private static let keys = ["layoutProfiles", "physicalSizeOverridesMM"]

    /// Copy any old-domain values into the standard domain, once.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)   // mark first, so a partial copy doesn't loop

        guard let old = UserDefaults(suiteName: oldDomain) else { return }
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}
