import Foundation

/// User-facing feature toggles. No UI yet — they read UserDefaults (default on),
/// so they're ready to wear a Settings pane later; until then,
/// `defaults write com.moxsf.ScreenQueen ghostMouse -bool NO` is the switch.
enum Prefs {
    /// The ghost mouse: the dashed pink arrow mirrored onto every other screen.
    static var ghostMouse: Bool { flag("ghostMouse") }
    /// Pink chrome on inactive displays (the understudy's costume).
    static var ghostChrome: Bool { flag("ghostChrome") }
    /// The beacon: the pulsing map-pin at the cursor's location on the schematic.
    static var beacon: Bool { flag("beacon") }

    /// Absent key = the default (on) — `bool(forKey:)` alone would read absent as off.
    private static func flag(_ key: String, default on: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? on : UserDefaults.standard.bool(forKey: key)
    }
}
