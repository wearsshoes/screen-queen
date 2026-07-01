#!/bin/bash
# Build Silkscreen as a release .app bundle and codesign it.
#
#   scripts/package.sh                 # ad-hoc signed (local use)
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/package.sh
#
# Output: build/Silkscreen.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Silkscreen"
BUNDLE_ID="com.moxsf.silkscreen"
SHORT_VERSION="${SHORT_VERSION:-1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"

# Build a drag-to-Applications DMG from the assembled .app. Uses only hdiutil (no
# third-party tooling). The DMG inherits the app's signature/notarization ticket, so
# call this *after* signing (and after stapling, for a notarized release).
make_dmg() {
	echo "▸ Building ${DMG}…"
	rm -f "$DMG"
	local staging
	staging="$(mktemp -d)"
	cp -R "$APP" "$staging/"
	ln -s /Applications "$staging/Applications"   # drag target
	hdiutil create -volname "$APP_NAME" -srcfolder "$staging" \
		-ov -format UDZO "$DMG" >/dev/null
	rm -rf "$staging"
	echo "✓ $DMG"
}

echo "▸ Building release binary…"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist: fill in the version placeholders.
sed -e "s/__SHORT_VERSION__/$SHORT_VERSION/" \
    -e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle an app icon if present (Resources/AppIcon.icns).
if [[ -f Resources/AppIcon.icns ]]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
		"$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "▸ Codesigning (identity: $IDENTITY)…"
# --options runtime enables the hardened runtime (required for notarization with a
# real Developer ID; harmless for ad-hoc). Deep-sign the whole bundle.
codesign --force --deep --options runtime \
	--identifier "$BUNDLE_ID" \
	--sign "$IDENTITY" "$APP"

echo "▸ Verifying…"
codesign --verify --strict --verbose=2 "$APP"

echo "✓ $APP"
if [[ "$IDENTITY" == "-" ]]; then
	echo "  (ad-hoc signed — for distribution, re-run with CODESIGN_IDENTITY set, then notarize.)"
	exit 0
fi

# Signed with a real identity but not notarizing: still emit a DMG on request
# (DMG=1), e.g. for a quick internal hand-off. Skipped when NOTARIZE=1, which
# builds the DMG from the *stapled* app further down.
if [[ "${DMG:-0}" == "1" && "${NOTARIZE:-0}" != "1" ]]; then
	make_dmg
fi

# Notarize when asked (needs a real Developer ID signature above). Provide either a
# stored credential profile or an Apple ID / team / app-specific-password triple:
#   NOTARIZE=1 NOTARY_PROFILE="silkscreen"                       scripts/package.sh
#   NOTARIZE=1 NOTARY_APPLE_ID=… NOTARY_TEAM_ID=… NOTARY_PASSWORD=…  scripts/package.sh
if [[ "${NOTARIZE:-0}" == "1" ]]; then
	ZIP="$BUILD_DIR/$APP_NAME.zip"
	echo "▸ Zipping for notarization…"
	ditto -c -k --keepParent "$APP" "$ZIP"

	echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
	if [[ -n "${NOTARY_PROFILE:-}" ]]; then
		xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
	else
		xcrun notarytool submit "$ZIP" \
			--apple-id "${NOTARY_APPLE_ID:?set NOTARY_APPLE_ID}" \
			--team-id "${NOTARY_TEAM_ID:?set NOTARY_TEAM_ID}" \
			--password "${NOTARY_PASSWORD:?set NOTARY_PASSWORD}" --wait
	fi

	echo "▸ Stapling ticket…"
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"
	rm -f "$ZIP"
	echo "✓ Notarized: $APP"

	# Package the stapled app into the distributable DMG.
	make_dmg
fi
