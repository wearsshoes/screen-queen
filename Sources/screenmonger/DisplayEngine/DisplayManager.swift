import AppKit
import CoreGraphics

/// The CoreGraphics read + write path.
///
/// All callers (UI, hotplug callback, and later hotkeys) run on the main thread,
/// so mutations are already serialized by main-thread confinement; we'll only
/// promote this to an `actor` if/when a writer needs to run off the main thread.
enum DisplayManager {

    /// Enumerate all active displays and capture a snapshot of each.
    ///
    /// `@MainActor` because we resolve human-readable names via `NSScreen`,
    /// which is main-actor isolated.
    @MainActor
    static func snapshot() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }

        let names = screenNamesByDisplayID()

        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelSize = CGSize(
                width: mode.map { CGFloat($0.pixelWidth) } ?? bounds.width,
                height: mode.map { CGFloat($0.pixelHeight) } ?? bounds.height
            )

            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let fingerprint = "\(vendor)-\(model)-\(serial)"

            // Prefer a manual calibration over EDID, which some monitors fake — but
            // the built-in's EDID is authoritative, so it always uses EDID (ignoring
            // any stale override from before it was made non-calibratable).
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let override = isBuiltin ? nil : CalibrationStore.override(for: fingerprint)
            let physMM = override ?? CGDisplayScreenSize(id)

            return DisplaySnapshot(
                id: id,
                name: names[id] ?? "Display \(id)",
                bounds: bounds,
                pixelSize: pixelSize,
                physicalSizeMM: physMM,
                physicalSizeIsCalibrated: override != nil,
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: isBuiltin,
                vendor: vendor,
                model: model,
                serial: serial,
                refreshHz: mode?.refreshRate ?? 0
            )
        }
    }

    // MARK: - Write path

    /// Reposition displays atomically. Origins are in the global desktop
    /// coordinate space (points, top-left origin). The system normalizes the
    /// result so it stays connected, so the live snapshot afterwards may differ
    /// slightly from what was requested — callers should re-snapshot to refresh.
    ///
    /// Returns `false` (and rolls back) if any individual configuration fails.
    /// `permanent: false` uses `.forSession` (in-memory, no disk write) — much
    /// cheaper, for live drags. The final drop should pass `permanent: true`.
    @discardableResult
    static func applyOrigins(_ origins: [CGDirectDisplayID: CGPoint], permanent: Bool = true) -> Bool {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            return false
        }
        for (id, origin) in origins {
            let err = CGConfigureDisplayOrigin(
                config, id,
                Int32(origin.x.rounded()),
                Int32(origin.y.rounded())
            )
            if err != .success {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(config, permanent ? .permanently : .forSession) == .success
    }

    /// Switch a single display to a new mode, atomically. Returns `false` (and
    /// rolls back) on failure. Resolution changes can blank a screen, so callers
    /// must pair this with the keep/revert confirmation.
    @discardableResult
    static func applyMode(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> Bool {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            return false
        }
        let err = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        if err != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: - Helpers

    /// Map CGDirectDisplayID → localized display name via NSScreen.
    @MainActor
    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber {
                result[number.uint32Value] = screen.localizedName
            }
        }
        return result
    }
}
