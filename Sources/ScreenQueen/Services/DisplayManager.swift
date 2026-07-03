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
        var rawIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &rawIDs, &count) == .success else {
            return []
        }
        // Mirrored slaves drop off the *active* list, so also pull the *online* list and
        // union them in — otherwise a mirrored display would vanish from the arranger
        // instead of showing in the mirror column.
        var onCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onCount))
        CGGetOnlineDisplayList(onCount, &onlineIDs, &onCount)
        // Mid-hotplug the list can transiently repeat an id or list mirror members;
        // dedupe so nothing downstream (id-keyed dicts) traps on a duplicate. Include an
        // online display only if it's a mirrored slave (a live master is already active).
        var seenIDs = Set<CGDirectDisplayID>()
        let ids = (rawIDs + onlineIDs.filter { CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay })
            .filter { seenIDs.insert($0).inserted }

        let names = screenNamesByDisplayID()

        var snapshots = ids.map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelSize = CGSize(
                width: mode.map { CGFloat($0.pixelWidth) } ?? bounds.width,
                height: mode.map { CGFloat($0.pixelHeight) } ?? bounds.height
            )

            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            // Calibration keys on the *base* v/m/s (two identical monitors share a
            // physical size, so calibration needn't distinguish them).
            let base = "\(vendor)-\(model)-\(serial)"

            // Prefer a manual calibration over EDID, which some monitors fake — but
            // the built-in's EDID is authoritative, so it always uses EDID (ignoring
            // any stale override from before it was made non-calibratable).
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let override = isBuiltin ? nil : CalibrationStore.override(for: base)
            let edidMM = CGDisplayScreenSize(id)
            let physMM = override ?? edidMM

            // The master this display mirrors (kCGNullDirectDisplay ⇒ not a slave).
            let master = CGDisplayMirrorsDisplay(id)
            let mirrorMaster = master == kCGNullDirectDisplay ? nil : master

            // A mirrored slave drops out of NSScreen.screens, so its localized name is
            // missing. When we *do* have the real name, remember it (keyed by fingerprint)
            // so we can recall it while mirrored; otherwise recall, then fall back.
            let name: String
            if let live = names[id] {
                NameStore.remember(live, for: base)
                name = live
            } else {
                name = NameStore.name(for: base) ?? (isBuiltin ? "Built-in Display" : Moniker.nickname(for: base))
            }

            return DisplaySnapshot(
                id: id,
                name: name,
                bounds: bounds,
                pixelSize: pixelSize,
                physicalSizeMM: physMM,
                physicalSizeIsCalibrated: override != nil,
                edidSizeMM: edidMM,
                isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: isBuiltin,
                mirrorMaster: mirrorMaster,
                vendor: vendor,
                model: model,
                serial: serial,
                refreshHz: mode?.refreshRate ?? 0
            )
        }

        // Disambiguate any monitors with an identical vendor/model/serial by their
        // physical connection (framebuffer location), so their fingerprints differ.
        var seen: [String: Int] = [:]   // base v/m/s → count so far
        for i in snapshots.indices {
            let d = snapshots[i]
            let order = seen[d.baseFingerprint, default: 0]; seen[d.baseFingerprint] = order + 1
            if let suffix = Topology.locationSuffix(product: Int(d.model), serial: Int(d.serial), orderAmongIdentical: order) {
                snapshots[i].fingerprintSuffix = suffix
            }
        }
        return snapshots
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

    /// Mirror `slave` onto `master` (slave shows the master's image), atomically.
    /// Returns false (and rolls back) on failure.
    @discardableResult
    static func setMirror(slave: CGDirectDisplayID, master: CGDirectDisplayID) -> Bool {
        configureMirror(slave, of: master)
    }

    /// Stop `id` mirroring (return it to its own image / the plane).
    @discardableResult
    static func unmirror(_ id: CGDirectDisplayID) -> Bool {
        configureMirror(id, of: kCGNullDirectDisplay)
    }

    private static func configureMirror(_ slave: CGDirectDisplayID, of master: CGDirectDisplayID) -> Bool {
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            return false
        }
        if CGConfigureDisplayMirrorOfDisplay(config, slave, master) != .success {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: - Helpers

    /// Whether `id` is a notched display (its screen reserves a top safe area) — the
    /// live NSScreen query, housed here so callers stay AppKit-free.
    @MainActor
    static func isNotched(_ id: CGDirectDisplayID) -> Bool {
        (NSScreen.screen(for: id)?.safeAreaInsets.top ?? 0) > 0
    }

    /// Map CGDirectDisplayID → localized display name via NSScreen.
    @MainActor
    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { result[id] = screen.localizedName }
        }
        return result
    }
}
