# Soft launch (Show HN)

**Blockers:**
* demo GIF — record the arranger, save to docs/demo.gif, uncomment the README image line
* run the notarized build (`NOTARIZE=1 NOTARY_PROFILE=screenqueen scripts/package.sh`)
  and attach build/ScreenQueen.dmg to a GitHub Release

**Before strangers run it (recommended, not blocking):**
* tests for the hotplug/profile logic (handleProfiles, repinSurvivors) — the code most
  likely to silently scramble someone's monitors
* first-launch onboarding: explain what it does + why it wants Accessibility

**Post-launch (can wait):**
* Homebrew cask
* Sparkle auto-update
* hardware matrix: Intel, clamshell, hub/dock, 3+ monitors, DisplayLink
* revoke the app-specific password exposed in chat; keychain profile keeps working