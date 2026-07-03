import AudioToolbox

/// The system alert sound, without dragging AppKit into callers (NSSound.beep's
/// only job here). Respects the user's chosen alert sound, same as NSBeep.
enum Chime {
    static func beep() {
        AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_UserPreferredAlert))
    }
}
