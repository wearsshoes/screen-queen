import Foundation

/// Every user-facing string in the app, in one place, so the copy can be reworked
/// without spelunking through view code. Each entry says where it appears and when.
/// Dynamic strings are functions; everything else is a constant. Dev-facing text
/// (DebugWindow, log messages) intentionally lives elsewhere.
enum Copy {

    // MARK: - Menu bar (the 🖥 status item's dropdown)

    /// First menu item; opens the arranger on every screen.
    static let menuShowArranger = "Show Arrangement  (⌘⌥F1)"
    /// Dev inspector window.
    static let menuDebug = "Debug…"
    /// Quit item at the bottom of the menu.
    static let menuQuit = "Quit Silkscreen"

    // MARK: - Arranger overlay chrome

    /// One-line help footer centered at the bottom of every arranger screen.
    static let footer = "Drag to rearrange · ⌘/arrows select · arrows nudge · ⌘⇧ align · ⌘ ± 0 resolution"
    /// Centered message when there are no displays to arrange (shouldn't happen, but).
    static let emptyState = "No displays detected"
    /// Highlight hint over the target tile while Option-dragging one display onto another.
    static let mirrorDropHint = "Mirror here"
    /// Third line of a tile's label when the display has no physical size yet
    /// (in place of the PPI readout). Invites the right-click calibration flow.
    static let calibratePrompt = "calibrate?"

    // MARK: - Bottom button bar (tooltips; the buttons themselves are icon-only)

    /// Reset button (⌘⌫): restore the layout captured when the arranger opened.
    static let resetTooltip = "Reset"
    /// Undo button (⌘Z): steps back one plane edit, or fires a pending Revert.
    static let undoTooltip = "Undo"
    /// Done button (⏎): commit and dismiss.
    static let doneTooltip = "Done"
    /// The A ↔ a resolution slider in the glass pill.
    static let sliderTooltip = "Resolution"
    /// Feed toggle while the live screen feed is running (figure.run icon).
    static let feedOnTooltip = "Stop live preview"
    /// Feed toggle while the feed is off (figure.stand icon).
    static let feedOffTooltip = "Show live preview"
    /// Scope toggle while the slider zooms every display proportionally.
    static let scopeAllTooltip = "Zoom all displays proportionally"
    /// Scope toggle while the slider zooms only the selected display.
    static let scopeOneTooltip = "Zoom the selected display only"

    // MARK: - Tile right-click menu

    /// Submenu holding the display's resolution ladder.
    static let menuResolution = "Resolution"
    /// Opens the type-a-diagonal calibration alert (external displays only).
    static let menuInputSize = "Input Size…"
    /// Opens the visual match-the-bars calibration (needs ≥2 displays).
    static let menuManualCalibration = "Manual Calibration…"
    /// Clears a manual size override, returning to what the monitor reports.
    static let menuResetSizeToEDID = "Reset Size to EDID"
    /// Built-in display only: reveal the full mode list beyond the clean 2× ladder.
    static let menuShowExtendedResolutions = "Show Extended Resolutions"

    // MARK: - Right-hand sidebar (mirrored displays + AirPlay)

    /// Section header above the mirrored-display cards.
    static let mirroredHeader = "Mirrored"
    /// Section header above the AirPlay session card.
    static let airplayHeader = "AirPlay"
    /// "⤷ mirrors <name>" line on a mirrored display's card.
    static func mirrorsLine(_ masterName: String) -> String { "⤷ mirrors \(masterName)" }
    /// Fallback for the mirror master's name when it can't be resolved.
    static let unknownDisplayName = "another display"
    /// Fallback for the AirPlay receiver's name when it can't be resolved.
    static let unknownAirPlayReceiver = "AirPlay receiver"
    /// AirPlay card body: what the session is doing.
    static let airplayBody = "Mirroring a window or app"
    /// AirPlay card fine print: we can see the session but not control it.
    static let airplayFinePrint = "Managed by macOS."
    /// AirPlay card button: opens Control Center's Screen Mirroring menu
    /// (the only place an AirPlay session can actually be changed or ended).
    static let airplayOpenSettings = "Open Screen Mirroring"

    // MARK: - Type-in calibration alert (right-click → Input Size…)

    /// Alert title. `name` is the display's name.
    static func calibrateTitle(_ name: String) -> String { "Calibrate \(name)" }
    /// Alert body. `edidInches` is what the monitor currently claims, e.g. "27.2".
    static func calibrateBody(edidInches: String) -> String {
        "Enter the screen's diagonal size in inches (corner to corner of the visible area). "
        + "EDID currently reports \(edidInches)\"."
    }
    /// Confirm button (shared with the match-calibration panel).
    static let save = "Save"
    /// Dismiss button (shared with the match-calibration panel).
    static let cancel = "Cancel"

    // MARK: - Match calibration (right-click → Manual Calibration…)

    /// Instruction at the top of the floating panel.
    static let matchInstruction = "Drag the bars until they look the same real size."
    /// All-caps caption over the big live readout.
    static let matchReadoutCaption = "INFERRED DIAGONAL"
    /// Readout placeholder before a size can be inferred.
    static let matchReadoutPlaceholder = "—"
    /// Label on the trusted display's bar.
    static let matchRoleReference = "Reference"
    /// Label on the bar of the display being calibrated.
    static let matchRoleTarget = "This display"
}
