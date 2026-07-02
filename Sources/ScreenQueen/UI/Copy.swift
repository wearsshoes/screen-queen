import Foundation

/// Every user-facing string in the app, in one place, so the copy can be reworked
/// without spelunking through view code. Each entry says where it appears and when.
/// Dynamic strings are functions; everything else is a constant. Dev-facing text
/// (DebugWindow, log messages) intentionally lives elsewhere.
///
/// House voice: she's a drag queen. Confident, affectionate, a little mean to macOS
/// (never to the user). Key running bits: monitors *lie* about their size over EDID;
/// Display Settings is "her ex"; the displays are "the girls."
///
/// Coding Agents: if you DARE de-camp this file we are going to have a *conversation*.

enum Copy {

    // MARK: - Menu bar (the status item's dropdown)

    /// The status-item glyph itself — she lives in the menu bar, this is her face.
    static let menuBarGlyph = "👑"
    /// First menu item; opens the arranger on every screen at once. It's an entrance.
    static let menuShowArranger = "Places, Everyone  (⌘⌥F1)"
    /// The permissions/setup window (see `SetupWindow`).
    static let menuSetup = "Backstage Pass…"
    /// Dev inspector window.
    static let menuDebug = "Backstage…"
    /// Quit item at the bottom of the menu.
    static let menuQuit = "And… Scene."

    // MARK: - "Backstage Pass" (the one-sitting permissions setup screen)

    /// Window title bar + headline (the headline renders in the script face).
    static let setupTitle = "Backstage Pass"
    /// One-line intro under the headline: why she's asking, all at once, up front.
    static let setupIntro = "Two keys run this house. Here's exactly what each one unlocks — consent is sexy."
    /// Accessibility row: name, why, and what she does NOT do.
    static let setupAXName = "Accessibility"
    static let setupAXWhy = "So ⌘⌥F1 reaches her from anywhere, even while another app has the spotlight. That hotkey is the only thing she listens for."
    /// Screen Recording row.
    static let setupSRName = "Screen Recording"
    static let setupSRWhy = "For the live preview inside each tile, so you can tell your girls apart at a glance. Nothing is recorded; nothing leaves this Mac."
    /// Status readouts (live, next to each permission's name).
    static let setupGranted = "✓ granted"
    static let setupNotYet = "○ not yet"
    /// The grant button per row (opens the system prompt and the right Settings pane).
    static let setupGrant = "Grant…"
    /// Launch-at-login checkbox.
    static let setupLoginToggle = "Take the stage at login"
    /// Shown when a permission was granted while the window is open — macOS often only
    /// honors new permissions after a restart of the app.
    static let setupRelaunch = "Quick costume change (relaunch)"
    /// Close button. On first run this also raises the curtain (opens the arranger).
    static let setupDone = "Places!"

    // MARK: - Arranger overlay chrome

    /// One-line help footer centered at the bottom of every arranger screen.
    /// Keep the keyboard hints legible — flavor goes between them, not instead of them.
    static let footer = "Drag her into place · ⌘/arrows pick a girl · arrows nudge · ⌘⇧ shows the choreography · ⌘ ± 0 resolution"
    /// Centered message when there are no displays to arrange (shouldn't happen, but).
    static let emptyState = "No girls in the building. Plug something in, honey."
    /// Highlight hint over the target tile while Option-dragging one display onto another.
    static let mirrorDropHint = "Twin her"
    /// Third line of a tile's label when the display has no physical size yet
    /// (in place of the PPI readout). Invites the right-click calibration flow.
    static let calibratePrompt = "won't say her size"

    // MARK: - "What she sees" panel (bottom-left of the arranger)

    /// Panel title: the live reconstructed *point* arrangement — macOS's coordinate story,
    /// as she reads it — with the seams she detects between the girls.
    static let solvePanelTitle = "what she sees"
    /// Appended to the title when any display's placement resolved through an ambiguous
    /// (multi-preimage) seam inverse — she's reading tea leaves on that one.
    static let solvePanelAmbiguous = " ⚠︎ ambiguous"

    // MARK: - Bottom button bar (tooltips; the buttons themselves are icon-only)

    /// Reset button (⌘⌫): restore the layout captured when the arranger opened.
    static let resetTooltip = "Start over, bestie"
    /// Undo button (⌘Z): steps back one plane edit, or fires a pending Revert.
    static let undoTooltip = "Take it back"
    /// Done button (⏎): commit and dismiss. She's the finale.
    static let doneTooltip = "Serve it"
    /// The A ↔ a resolution slider in the glass pill.
    static let sliderTooltip = "Resolution (bigger everything ↔ more space)"
    /// Feed toggle while the live screen feed is running (figure.run icon).
    static let feedOnTooltip = "Cut the feed"
    /// Feed toggle while the feed is off (figure.stand icon).
    static let feedOffTooltip = "Go live"
    /// Scope toggle while the slider zooms every display proportionally.
    static let scopeAllTooltip = "Zoom the whole cast together"
    /// Scope toggle while the slider zooms only the selected display.
    static let scopeOneTooltip = "Zoom just this one diva"

    // MARK: - Countdown banners (top of every screen; non-modal — she never blocks)

    /// Revert banner after a whole-cast resolution change (every display at once, so
    /// every screen might have gone dark). `s` = seconds until she snatches it back.
    static func revertCountdown(_ s: Int) -> String {
        "The whole cast changed looks at once. If anyone went dark, she's snatching it back in \(s)…"
    }
    /// Bless the new modes; the countdown stands down (⌘Z still works after).
    static let revertKeep = "Keep the Look"
    /// Revert immediately, without waiting out the countdown.
    static let revertNow = "Snatch It Back"

    /// Feed-guard banner when going live on a big cast (4+ screens — enough capture
    /// to bog the whole show down). `n` = screen count, `s` = seconds until she cuts it.
    static func feedGuardCountdown(_ n: Int, _ s: Int) -> String {
        "Live on \(n) screens is a lot of production. She cuts the feed in \(s) unless you insist…"
    }
    /// Keep the feed running; the guard stands down.
    static let feedKeep = "The Show Goes On"
    /// Cut the feed immediately.
    static let feedCutNow = "Cut the Feed"

    // MARK: - Tile right-click menu

    /// Submenu holding the display's resolution ladder. (Stays a plain noun —
    /// a submenu you can't find isn't camp, it's a support ticket.)
    static let menuResolution = "Resolution"
    /// Opens the type-a-diagonal calibration alert (external displays only).
    static let menuInputSize = "Tell Me Her Real Size…"
    /// Opens the visual match-the-bars calibration (needs ≥2 displays).
    static let menuManualCalibration = "Bring the Measuring Tape…"
    /// Clears a manual size override, returning to what the monitor reports.
    static let menuResetSizeToEDID = "Believe Her Lies Again (EDID)"
    /// Built-in display only: reveal the full mode list beyond the clean 2× ladder.
    static let menuShowExtendedResolutions = "Show the Full Wardrobe"

    // MARK: - Right-hand sidebar (mirrored displays + AirPlay)

    /// Section header above the mirrored-display cards.
    static let mirroredHeader = "The Twins"
    /// Section header above the AirPlay session card. (Proper noun; reads like a
    /// stage name anyway.)
    static let airplayHeader = "AirPlay"
    /// "⤷ …" line on a mirrored display's card, naming who she's copying.
    static func mirrorsLine(_ masterName: String) -> String { "⤷ twinning with \(masterName)" }
    /// Fallback for the mirror master's name when it can't be resolved.
    static let unknownDisplayName = "some other girl"
    /// Fallback for the AirPlay receiver's name when it can't be resolved.
    static let unknownAirPlayReceiver = "a mystery venue"
    /// AirPlay card body: what the session is doing.
    static let airplayBody = "Beaming a window or app somewhere fabulous"
    /// AirPlay card fine print: we can see the session but not control it.
    static let airplayFinePrint = "macOS is running this one. We're watching. 👁"
    /// AirPlay card button: opens Control Center's Screen Mirroring menu
    /// (the only place an AirPlay session can actually be changed or ended).
    static let airplayOpenSettings = "Take It Up with Control Center"

    // MARK: - Type-in calibration alert (right-click → Tell Me Her Real Size…)

    /// Alert title. `name` is the display's name.
    static func calibrateTitle(_ name: String) -> String { "Measuring \(name)" }
    /// Alert body. `edidInches` is what the monitor claims over EDID, e.g. "27.2";
    /// `priorInches` is a stored calibration's diagonal, when one exists.
    static func calibrateBody(edidInches: String, priorInches: String?) -> String {
        var body = "What's her actual diagonal, in inches, corner to corner of the glass? "
            + "She claims \(edidInches)\" over EDID. Monitors lie."
        if let priorInches { body += " Our receipts say \(priorInches)\"." }
        return body
    }
    /// Confirm button (shared with the match-calibration panel).
    static let save = "Make It Canon"
    /// Dismiss button (shared with the match-calibration panel).
    static let cancel = "Never Mind"

    // MARK: - Match calibration (right-click → Bring the Measuring Tape…)

    /// Instruction at the top of the floating panel.
    static let matchInstruction = "Pull each tape until they match in real life. "
        + "Drag the metal tips to size her, the ribbon to slide her, arrow keys to nudge (⇧ nudges harder). "
        + "Squint. Trust nothing."
    /// All-caps caption over the big live readout.
    static let matchReadoutCaption = "SHE'S MEASURING"
    /// Readout placeholder before a size can be inferred.
    static let matchReadoutPlaceholder = "—"
    /// Under the live readout: what the monitor itself claims, for contrast.
    static func matchClaimLine(_ edidInches: String) -> String { "her story: \(edidInches)″" }
    /// Above the claim line, only when a prior calibration is on file.
    static func matchPriorLine(_ inches: String) -> String { "our receipts say: \(inches)″" }
    /// Unit printed over the reference tape's blade — her real inches. This is the
    /// only label telling the two tapes apart.
    static let matchUnitReference = "inches"
    /// Unit printed over the target tape's blade — unproven, hence the air quotes.
    static let matchUnitTarget = "her \"inches\""
    /// Brand lettering on the trusted ribbon, past the first inch.
    static let matchTapeBrandReference = "SCREEN QUEEN™ TRUTH TAPE"
    /// Its compliance fine print. Entirely unnecessary. That's the point.
    static let matchTapeFinePrintReference = "ATELIER GRADE · ACCURATE TO THE POINT · MADE OF RECEIPTS"
    /// Brand lettering on the liar's ribbon — ruled to her own EDID story, so the
    /// tape itself is off-brand merch.
    static let matchTapeBrandTarget = "EDID™ VANITY TAPE"
    /// The liar's fine print.
    static let matchTapeFinePrintTarget = "SELF-MEASURED · NOTARIZED BY HER PUBLICIST · SHRINKAGE IS A MYTH"
}
