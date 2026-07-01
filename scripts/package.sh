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
fi
