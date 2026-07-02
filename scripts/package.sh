#!/bin/bash
# Build Screen Queen as a release .app bundle and codesign it.
#
#   scripts/package.sh                 # ad-hoc signed (local use)
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/package.sh
#
# Output: build/ScreenQueen.app
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCT_NAME="ScreenQueen"   # SPM product
APP_NAME="ScreenQueen"       # the marquee
BUNDLE_ID="com.moxsf.screenqueen"
SHORT_VERSION="${SHORT_VERSION:-1.0}"
BUILD_VERSION="${BUILD_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Resolve the codesigning identity:
#   - CODESIGN_IDENTITY set  → use it verbatim (must resolve, or we bail).
#   - unset                  → auto-detect a "Developer ID Application" identity;
#                              fall back to "-" (ad-hoc) if none is installed.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
	IDENTITY="$CODESIGN_IDENTITY"
	if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
		echo "✗ No codesigning identity matching: $IDENTITY" >&2
		echo "  Installed identities:" >&2
		security find-identity -v -p codesigning | sed 's/^/    /' >&2
		exit 1
	fi
else
	IDENTITY="$(security find-identity -v -p codesigning \
		| grep 'Developer ID Application' | head -1 \
		| sed -E 's/.*"(.*)".*/\1/')"
	IDENTITY="${IDENTITY:--}"   # "-" = ad-hoc when no Developer ID is installed
fi

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
# Capture the DMG=1 request before DMG is reused as the output path below (the path
# assignment used to clobber the flag, so the non-notarized DMG could never build).
WANT_DMG="${DMG:-0}"
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
swift build -c release --product "$PRODUCT_NAME"
BIN="$(swift build -c release --product "$PRODUCT_NAME" --show-bin-path)/$PRODUCT_NAME"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The SPM resource bundle (fonts). `Bundle.module` fatalErrors at first use if it can't
# find this next to Contents/Resources — the app then launches fine but dies the moment
# the arranger opens. Fail loudly here rather than ship that.
RES_BUNDLE="$(dirname "$BIN")/${PRODUCT_NAME}_${PRODUCT_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
	cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
	echo "✗ Missing SPM resource bundle: $RES_BUNDLE" >&2
	exit 1
fi

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
if [[ "$WANT_DMG" == "1" && "${NOTARIZE:-0}" != "1" ]]; then
	make_dmg
fi

# Notarize when asked (needs a real Developer ID signature above). Provide either a
# stored credential profile or an Apple ID / team / app-specific-password triple:
#   NOTARIZE=1 NOTARY_PROFILE="screenqueen"                      scripts/package.sh
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
