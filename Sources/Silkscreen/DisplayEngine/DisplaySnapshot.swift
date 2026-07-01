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

    /// Physical size in millimeters. From EDID by default, but replaced by a
    /// user calibration when EDID is missing or wrong (see `CalibrationStore`).
    let physicalSizeMM: CGSize

    /// Whether `physicalSizeMM` came from a manual calibration rather than EDID.
    let physicalSizeIsCalibrated: Bool

    /// Diagonal of the physical size, in inches (0 if size unknown).
    var diagonalInches: Double {
        let w = Double(physicalSizeMM.width), h = Double(physicalSizeMM.height)
        return (w * w + h * h).squareRoot() / 25.4
    }

    let isMain: Bool
    let isBuiltin: Bool

    /// The display this one mirrors (its mirror-set master), or nil when it isn't a
    /// mirrored slave. A mirrored slave shows the master's image; in the arranger it
    /// leaves the physical plane and lives in the mirror column instead.
    var mirrorMaster: CGDirectDisplayID? = nil

    /// Whether this display is a mirrored slave (mirrors another display).
    var isMirrored: Bool { mirrorMaster != nil }

    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    /// A per-connection suffix (framebuffer location) that distinguishes this display
    /// from another with an identical vendor/model/serial. Empty when there's no such
    /// collision. See `Topology`.
    var fingerprintSuffix: String = ""

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

    /// Effective *points* per physical inch — the density that actually governs
    /// how big a dragged window looks, since macOS preserves a window's point
    /// size across displays. Two screens with equal `pointsPerInch` show a
    /// dragged element at the same physical size. `nil` when EDID size is absent.
    var pointsPerInch: Double? {
        guard physicalSizeMM.width > 1 else { return nil }
        let inches = Double(physicalSizeMM.width) / 25.4
        guard inches > 0 else { return nil }
        return Double(bounds.width) / inches
    }

    /// Stable identity for a physical display across reconnects: vendor/model/serial,
    /// plus a per-connection topology suffix when two connected monitors would
    /// otherwise share it (see `Topology`).
    var fingerprint: String {
        let base = "\(vendor)-\(model)-\(serial)"
        return fingerprintSuffix.isEmpty ? base : "\(base)@\(fingerprintSuffix)"
    }

    /// A stable, memorable nickname derived from the fingerprint (a temporary handle
    /// until the user can assign custom names).
    var nickname: String { Moniker.nickname(for: fingerprint) }

    /// A copy with new `bounds` — for building a *prospective* layout (drag or
    /// resolution preview) without actually reconfiguring the displays.
    func with(bounds: CGRect) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, name: name, bounds: bounds,
            pixelSize: pixelSize, physicalSizeMM: physicalSizeMM,
            physicalSizeIsCalibrated: physicalSizeIsCalibrated,
            isMain: isMain, isBuiltin: isBuiltin,
            mirrorMaster: mirrorMaster,
            vendor: vendor, model: model, serial: serial,
            fingerprintSuffix: fingerprintSuffix, refreshHz: refreshHz
        )
    }

    func movedTo(origin: CGPoint) -> DisplaySnapshot {
        with(bounds: CGRect(origin: origin, size: bounds.size))
    }
}
