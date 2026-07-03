import AppKit

/// The per-tile right-click context menu: resolution submenu plus size-calibration
/// entries, and the `@objc` actions they fire. Builds off the display under the cursor;
/// the actions hand off to the `commander`.
extension Stage {

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let d = display(at: p) else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: d.nickname, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(resolutionMenuItem(for: d))
        // The built-in's EDID physical size is authoritative — no size overrides for it.
        if !d.isBuiltin {
            menu.addItem(.separator())
            menu.addItem(displayItem(Copy.menuInputSize, #selector(calibrateFromMenu(_:)), d.id))
            if displays.count > 1 {
                menu.addItem(displayItem(Copy.menuManualCalibration, #selector(calibrateVisualFromMenu(_:)), d.id))
            }
            if d.physicalSizeIsCalibrated {
                menu.addItem(displayItem(Copy.menuResetSizeToEDID, #selector(resetCalibrationFromMenu(_:)), d.id))
            }
        }
        return menu
    }

    /// A menu item targeting this stage, carrying the display id it acts on.
    private func displayItem(_ title: String, _ action: Selector, _ id: CGDirectDisplayID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = NSNumber(value: id)
        return item
    }

    private func resolutionMenuItem(for d: DisplaySnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: Copy.menuResolution, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = CGDisplayCopyDisplayMode(d.id)
        for mode in modesList(for: d) {
            let mi = NSMenuItem(title: mode.label, action: #selector(setModeFromMenu(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = ModeChoice(id: d.id, mode: mode.cgMode)
            if let current, ModeCatalog.sameMode(current, mode.cgMode) { mi.state = .on }
            submenu.addItem(mi)
        }
        item.submenu = submenu
        return item
    }

    private final class ModeChoice {
        let id: CGDirectDisplayID; let mode: CGDisplayMode
        init(id: CGDirectDisplayID, mode: CGDisplayMode) { self.id = id; self.mode = mode }
    }

    @objc private func setModeFromMenu(_ s: NSMenuItem) {
        guard let c = s.representedObject as? ModeChoice else { return }
        let size = CGSize(width: CGFloat(c.mode.width), height: CGFloat(c.mode.height)) // "Looks like" points
        let ds = displays.map { $0.id == c.id ? $0.with(bounds: CGRect(origin: $0.bounds.origin, size: size)) : $0 }
        commander?.setResolution(c.id, c.mode, SchematicLayout.toPoints(rects: plane, displays: ds))
    }
    @objc private func calibrateFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { commander?.calibrate($0.uint32Value) } }
    @objc private func calibrateVisualFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { commander?.calibrateVisual($0.uint32Value) } }
    @objc private func resetCalibrationFromMenu(_ s: NSMenuItem) { (s.representedObject as? NSNumber).map { commander?.resetCalibration($0.uint32Value) } }
}
