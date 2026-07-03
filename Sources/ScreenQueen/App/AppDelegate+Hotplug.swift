import AppKit

/// Hotplug/profile handling: when the connected display *set* changes, apply the best
/// saved profile (or dock/select a newcomer, or re-pin survivors); when it hasn't,
/// remember the settled layout as this set's profile. The pure rules live in
/// `HotplugMath` (Domain, tested); this file is the orchestration against the live
/// system.
extension AppDelegate {

    /// Auto-save / auto-restore layout profiles. When the connected display *set*
    /// changes (a hotplug), apply the best saved profile for it; otherwise (a settled
    /// state after our own commit) save the current layout as the profile for this set.
    /// If a newly-plugged display isn't covered by any profile, open the arranger and
    /// select it so the user can place it.
    func handleProfiles(_ displays: [DisplaySnapshot]) {
        let set = Set(displays.map(\.fingerprint))
        let baseSet = displays.map { "\($0.vendor)-\($0.model)-\($0.serial)" }
        let ids = Set(displays.map(\.id))
        let newcomerIDs = ids.subtracting(lastDisplayIDs)
        let removed = lastDisplayIDs.subtracting(ids)
        let priorOrigins = lastOrigins
        defer {
            lastDisplaySet = set; lastBaseSet = baseSet; lastDisplayIDs = ids
            lastOrigins = Dictionary(displays.map { ($0.id, $0.bounds.origin) }, uniquingKeysWith: { a, _ in a })
        }
        guard !set.isEmpty else { return }

        guard set != lastDisplaySet else {
            LayoutStore.store(LayoutStore.profile(from: displays))   // settled → remember this layout
            return
        }

        // A display left: macOS may have moved a survivor to a stale single-monitor
        // layout. Re-pin survivors to their prior positions; if that's impossible
        // (e.g. the middle of three was removed), open the arranger to solve instead.
        if !removed.isEmpty, newcomerIDs.isEmpty {
            repinSurvivors(displays, priorOrigins: priorOrigins)
            return
        }

        // A twin of an already-present monitor just joined: adding it re-suffixes the
        // existing one, but we must NOT reshuffle the existing displays. Leave them put,
        // dock the newcomer flush to the nearest free edge, and arrange it.
        if HotplugMath.joinedIdenticalTwin(now: baseSet, before: lastBaseSet) {
            dockNewcomer(newcomerIDs, in: displays)
            selectNewcomer(newcomerIDs, in: displays)
            return
        }

        let profile = LayoutStore.bestMatch(for: Array(set))
        if let profile { applyProfile(profile, to: displays) }

        // Any newly-connected display not covered by the applied profile is
        // "unrecognized" — surface the arranger and select it.
        let recognized = profile.map { Set($0.keys) } ?? []
        let unrecognized = displays.filter { newcomerIDs.contains($0.id) && !recognized.contains($0.fingerprint) }
        selectNewcomer(Set(unrecognized.map(\.id)), in: displays)

        // A brand-new girl gets measured on arrival: if she's external, never
        // calibrated, and this is a genuine hotplug (not launch populating the
        // set), bring the tape out immediately, over the arranger.
        if !lastDisplayIDs.isEmpty,
           let newbie = unrecognized.first(where: { !$0.isBuiltin && !$0.physicalSizeIsCalibrated }) {
            calibrateVisual(newbie.id)
        }
    }

    /// Re-apply the survivors' prior origins so the remaining monitor(s) don't get
    /// moved by macOS's stale layout. If those origins no longer form a valid
    /// arrangement (a gap — e.g. the middle of three was removed), open the arranger to
    /// solve to a next-best layout instead.
    private func repinSurvivors(_ displays: [DisplaySnapshot], priorOrigins: [CGDirectDisplayID: CGPoint]) {
        var rects: [CGRect] = []
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        for d in displays {
            guard let o = priorOrigins[d.id] else { showWindow(); return }   // unknown prior → let user solve
            origins[d.id] = o
            rects.append(CGRect(origin: o, size: d.bounds.size))
            if d.isMain { mainID = d.id }
        }
        guard HotplugMath.arrangementIsValid(rects) else { showWindow(); return }   // gap/overlap → solve in arranger
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// Dock a newly-joined display flush to the nearest free edge of the existing
    /// arrangement (macOS may have dropped it overlapping or off in the void).
    private func dockNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let newID = newcomerIDs.first,
              let newD = displays.first(where: { $0.id == newID }) else { return }
        let others = displays.filter { $0.id != newID }
        guard !others.isEmpty,
              let docked = HotplugMath.dockedOrigin(for: newD.bounds, among: others.map(\.bounds))
        else { return }   // no neighbors, or the OS spot already touches cleanly
        var origins = originMap(of: displays)
        origins[newID] = docked
        let mainID = displays.first(where: \.isMain)?.id
        preservingCursor { DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true) }
    }

    /// Open the arranger (if needed) and select the first newly-connected display.
    private func selectNewcomer(_ newcomerIDs: Set<CGDirectDisplayID>, in displays: [DisplaySnapshot]) {
        guard let id = newcomerIDs.first, displays.contains(where: { $0.id == id }) else { return }
        if !arranger.isVisible { showWindow() }
        arranger.state.selectedID = id
        arranger.state.notify()
    }

    /// Apply a saved profile to the matching connected displays: set each present
    /// display's mode, then its origin (pinning main at 0,0).
    private func applyProfile(_ profile: LayoutStore.Profile, to displays: [DisplaySnapshot]) {
        // `uniqueKeysWithValues` would trap on a fingerprint collision; keep-first
        // instead (the topology suffix should prevent collisions, but degrade safely).
        let byFingerprint = Dictionary(displays.map { ($0.fingerprint, $0) }, uniquingKeysWith: { a, _ in a })
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var mainID: CGDirectDisplayID?
        preservingCursor {
            for (fp, e) in profile {
                guard let d = byFingerprint[fp] else { continue }
                if let mode = ModeCatalog.mode(for: d.id, matching: e) { DisplayManager.applyMode(mode, to: d.id) }
                origins[d.id] = CGPoint(x: e.originX, y: e.originY)
                if e.isMain { mainID = d.id }
            }
            return DisplayManager.applyOrigins(pin(origins, mainID: mainID), permanent: true)
        }
    }
}
