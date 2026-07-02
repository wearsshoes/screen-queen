import CoreGraphics
import Foundation
import IOKit

/// Reads each display's framebuffer location from the IORegistry, to disambiguate
/// two monitors with an identical vendor/model/serial (real in some offices). The
/// framebuffer node (`dispext0`, `dispext1`, …) has a stable location per physical
/// connection, so two identical panels in different ports get distinct keys. Swapping
/// their cables swaps identities — acceptable, and the best signal available on
/// Apple Silicon (where CoreGraphics ↔ port linkage is otherwise gone).
enum Topology {

    /// One framebuffer's identity: the EDID product/serial it reports plus its stable
    /// registry location.
    private struct FB { let product: Int; let serial: Int; let location: String }

    /// framebuffer entries, in registry order.
    private static func framebuffers() -> [FB] {
        var result: [FB] = []
        var it: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(it) }

        var s = IOIteratorNext(it)
        while s != 0 {
            defer { IOObjectRelease(s); s = IOIteratorNext(it) }
            guard let da = prop(s, "DisplayAttributes") as? [String: Any],
                  let pa = da["ProductAttributes"] as? [String: Any] else { continue }
            let product = (pa["ProductID"] as? Int) ?? -1
            let serial = (pa["SerialNumber"] as? Int) ?? 0
            result.append(FB(product: product, serial: serial, location: parentLocation(of: s)))
        }
        return result
    }

    /// A per-connection location suffix to append to `id`'s fingerprint, distinguishing
    /// it from another display with the same product/serial. `nil` when there's no
    /// ambiguity (or no reading), so the plain fingerprint is used.
    ///
    /// `orderAmongIdentical` is this display's index among the currently-connected
    /// displays that share its product/serial (stable within a session), used to pick
    /// which framebuffer of an identical pair it maps to.
    static func locationSuffix(product: Int, serial: Int, orderAmongIdentical: Int) -> String? {
        let matches = framebuffers().filter { $0.product == product && $0.serial == serial }
        guard matches.count > 1 else { return nil }   // no collision → no suffix needed
        let sorted = matches.sorted { $0.location < $1.location }
        guard orderAmongIdentical < sorted.count else { return nil }
        return sorted[orderAmongIdentical].location
    }

    private static func prop(_ s: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The registry location of the framebuffer's parent (the `dispextN` node).
    private static func parentLocation(of fb: io_registry_entry_t) -> String {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(fb, kIOServicePlane, &parent) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(parent) }
        var loc = [CChar](repeating: 0, count: 256)
        return IORegistryEntryGetLocationInPlane(parent, kIOServicePlane, &loc) == KERN_SUCCESS
            ? String(cString: loc) : ""
    }
}
