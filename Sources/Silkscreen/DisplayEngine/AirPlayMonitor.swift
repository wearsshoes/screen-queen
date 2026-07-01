import CoreAudio
import Foundation
import IOKit.pwr_mgt

/// A live AirPlay session that sends *visual* content (a display, the whole screen,
/// or — the case that started this — a single window in Sequoia's "Window or App"
/// mode) to a receiver.
///
/// The "Window or App" mode is invisible to the display layer: such a receiver is
/// not a `CGDirectDisplayID` and doesn't appear in `system_profiler`'s display list.
/// The one public, reliable tell is a power-management assertion the AirPlay agent
/// raises specifically for a *screen* session (audio-only AirPlay does not raise it).
/// We read that assertion, then best-effort attach the receiver's name from CoreAudio.
struct AirPlaySession: Equatable {
    /// The receiver's name if we could recover it (CoreAudio names the AirPlay output
    /// device after the receiver during a screen share — but sometimes only reports a
    /// generic "AirPlay"). `nil` when no better-than-generic name was available.
    let receiverName: String?
}

enum AirPlayMonitor {

    /// The assertion the AirPlay UI agent raises while a *visual* session is active.
    /// Verified empirically: present for extended / entire-screen / window-or-app
    /// shares, absent for audio-only AirPlay and when nothing is being sent.
    private static let screenAssertionName = "com.apple.airplay.disableUserIdleDisplaySleep"

    /// The current visual AirPlay session, or nil if none is active.
    static func currentSession() -> AirPlaySession? {
        guard hasVisualSession() else { return nil }
        return AirPlaySession(receiverName: receiverName())
    }

    /// Whether any process holds the AirPlay *screen* power assertion — our proxy for
    /// "a visual AirPlay session is active", including the CGDisplay-invisible
    /// "Window or App" mode.
    private static func hasVisualSession() -> Bool {
        var assertionsByPID: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertionsByPID) == kIOReturnSuccess,
              let byPID = assertionsByPID?.takeRetainedValue() as? [AnyHashable: [[String: Any]]]
        else { return false }

        for assertions in byPID.values {
            for assertion in assertions {
                // The assertion's *name* carries the AirPlay tag (its type is the
                // generic PreventUserIdleDisplaySleep, so match on name, not type).
                if let name = assertion[kIOPMAssertionNameKey as String] as? String,
                   name == screenAssertionName {
                    return true
                }
            }
        }
        return false
    }

    /// Best-effort receiver name: the name of the current AirPlay-transport audio
    /// output device, when it's more specific than the generic "AirPlay". Returns nil
    /// otherwise (a silent screen share may register no audio device, and audio-only
    /// sessions relabel the device generically).
    private static func receiverName() -> String? {
        for device in audioDeviceIDs() where transportType(device) == kAudioDeviceTransportTypeAirPlay {
            if let name = deviceName(device), name != "AirPlay", !name.isEmpty {
                return name
            }
        }
        return nil
    }

    // MARK: - CoreAudio helpers

    private static func audioDeviceIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name as String
    }
}
