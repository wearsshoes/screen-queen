import CoreGraphics
import Foundation

/// An immutable, value-typed view of a single display at a moment in time.
///
/// This is the unit the whole DisplayEngine traffics in: the read path produces
/// `[DisplaySnapshot]`, the UI renders them, and (in later phases) the write path
/// diffs a desired snapshot against the live one to compute the minimal set of
/// CoreGraphics configuration calls.
struct DisplaySnapshot: Identifiable, Equatable {
    /// CoreGraphics display id. Stable while a display stays connected, but NOT
    /// stable across reconnects — use `fingerprint` for persistence.
    let id: CGDirectDisplayID

    /// Human-readable name (from NSScreen.localizedName), e.g. "DELL U2720Q".
    let name: String

    /// Position + size in the global desktop coordinate space, in points.
    /// Origin is top-left, y grows downward (CoreGraphics global space).
    /// `bounds.size` is the "Looks like" (effective point) resolution.
    let bounds: CGRect

    /// Native backing resolution in pixels.
    let pixelSize: CGSize

    /// Physical size from EDID, in millimeters. May be `.zero` for displays
    /// behind dumb adapters/KVMs that don't pass EDID through — those need the
    /// manual calibration fallback (Phase 4).
    let physicalSizeMM: CGSize

    let isMain: Bool
    let isBuiltin: Bool

    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// Refresh rate in Hz (0 if unknown, e.g. some built-in panels).
    let refreshHz: Double

    /// True when the native pixel resolution exceeds the point resolution,
    /// i.e. the display is running a HiDPI ("Retina"/scaled) mode.
    var isHiDPI: Bool { pixelSize.width > bounds.width }

    /// Physical pixels per inch, derived from EDID. `nil` when the physical
    /// size is missing/implausible.
    var ppi: Double? {
        guard physicalSizeMM.width > 1 else { return nil }
        let inches = Double(physicalSizeMM.width) / 25.4
        guard inches > 0 else { return nil }
        return Double(pixelSize.width) / inches
    }

    /// Stable identity for a physical display across reconnects. Serial is 0 on
    /// some panels; vendor+model still disambiguates most coworking setups.
    var fingerprint: String { "\(vendor)-\(model)-\(serial)" }
}
