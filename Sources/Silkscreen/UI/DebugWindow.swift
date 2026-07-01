import AppKit

/// A small debug window: the displays seen so far (with fingerprints) and the saved
/// layout profiles, plus a button to reset the saved profiles.
@MainActor
final class DebugWindow {

    private var window: NSWindow?
    private var textView: NSTextView?

    func show() {
        if window == nil { build() }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Silkscreen — Debug"
        w.isReleasedWhenClosed = false
        // The arranger sits at the shielding level; lift the debug window above it so it
        // isn't hidden behind the overlay.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = tv
        self.textView = tv

        let reset = NSButton(title: "Reset Saved Layouts", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(reset)
        container.addSubview(refreshButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -8),
            reset.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            reset.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            refreshButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            refreshButton.centerYAnchor.constraint(equalTo: reset.centerYAnchor),
        ])
        w.contentView = container
        w.center()
        window = w
    }

    @objc private func resetTapped() {
        LayoutStore.clearAll()
        refresh()
    }

    @objc private func refreshTapped() { refresh() }

    private func refresh() {
        var s = "CONNECTED DISPLAYS\n\n"
        for d in DisplayManager.snapshot() {
            s += "• \(d.name)  “\(d.nickname)”\(d.isMain ? "  [main]" : "")\(d.isBuiltin ? "  [builtin]" : "")\n"
            s += "    fingerprint: \(d.fingerprint)\n"
            s += String(format: "    %.0f×%.0f pt · %.0f×%.0f px\n\n",
                        d.bounds.width, d.bounds.height, d.pixelSize.width, d.pixelSize.height)
        }

        let profiles = LayoutStore.allProfiles()
        // Suppress nicknames for the built-in (no external identity to moniker).
        let builtinFP = DisplayManager.snapshot().first(where: \.isBuiltin)?.fingerprint

        s += "SAVED PROFILES (\(profiles.count))\n\n"
        for (_, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            let names = profile.values.map(\.name).filter { !$0.isEmpty }.sorted()
            s += "• \(names.isEmpty ? "—" : names.joined(separator: ", "))\n"
            for (fp, e) in profile.sorted(by: { $0.key < $1.key }) {
                let nick = fp == builtinFP ? "" : "  “\(Moniker.nickname(for: fp))”"
                s += String(format: "    %@%@%@  @(%.0f,%.0f)  %d×%d\n",
                            e.name.isEmpty ? "?" : e.name, nick,
                            e.isMain ? " [main]" : "", e.originX, e.originY, e.pointWidth, e.pointHeight)
            }
            s += "\n"
        }

        let cals = CalibrationStore.allOverrides()
        s += "STORED CALIBRATIONS (\(cals.count))\n\n"
        for (fp, size) in cals.sorted(by: { $0.key < $1.key }) {
            let nick = fp == builtinFP ? "" : "  “\(Moniker.nickname(for: fp))”"
            s += String(format: "• %@%@  %.1f×%.1f mm  (%.1f″)\n",
                        fp, nick, size.width, size.height,
                        (Double(size.width) * Double(size.width) + Double(size.height) * Double(size.height)).squareRoot() / 25.4)
        }

        textView?.string = s
    }
}
