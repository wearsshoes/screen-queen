import SwiftUI

/// A small debug window: the displays seen so far (with fingerprints) and the saved
/// layout profiles, plus a button to reset the saved profiles.
@MainActor
final class DebugWindow {

    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        // Fresh controller per show = fresh dump, matching the old refresh-on-show.
        window?.contentViewController = NSHostingController(rootView: DebugView())
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Screen Queen — Debug"
        w.isReleasedWhenClosed = false
        // The arranger sits at the shielding level; lift the debug window above it so it
        // isn't hidden behind the overlay.
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        w.setContentSize(NSSize(width: 560, height: 460))
        w.center()
        window = w
    }
}

struct DebugView: View {
    @State private var dump = DebugView.makeDump()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(dump)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            HStack {
                Button("Refresh") { dump = Self.makeDump() }
                Spacer()
                Button("Reset Saved Layouts") {
                    LayoutStore.clearAll()
                    dump = Self.makeDump()
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 460)
    }

    private static func makeDump() -> String {
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
        return s
    }
}
