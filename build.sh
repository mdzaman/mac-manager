#!/bin/bash
#
# Builds Mac Manager.app from source. No package manager, no Xcode project —
# just swiftc, the Command Line Tools, and the app bundle laid out by hand.
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mac Manager"
BUNDLE_ID="com.local.macmanager"
VERSION="1.0"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
ARCH="$(uname -m)"
DEPLOY_TARGET="11.0"

echo "==> Building $APP_NAME for $ARCH (deployment target macOS $DEPLOY_TARGET)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# ---------------------------------------------------------------- compile ---
SOURCES=$(find Sources -name '*.swift' | sort)
echo "==> Compiling $(echo "$SOURCES" | wc -l | tr -d ' ') source files"

swiftc \
  -O \
  -parse-as-library \
  -target "${ARCH}-apple-macosx${DEPLOY_TARGET}" \
  -o "$APP_DIR/Contents/MacOS/MacManager" \
  $SOURCES

# ------------------------------------------------------------------ icon ---
if [ -f Tools/MakeIcon.swift ]; then
  echo "==> Generating app icon"
  ICON_TMP="$BUILD_DIR/icon.iconset"
  rm -rf "$ICON_TMP"
  mkdir -p "$ICON_TMP"

  swiftc -O -parse-as-library \
    -target "${ARCH}-apple-macosx${DEPLOY_TARGET}" \
    -o "$BUILD_DIR/makeicon" Tools/MakeIcon.swift 2>/dev/null &&
  "$BUILD_DIR/makeicon" "$ICON_TMP" &&
  iconutil -c icns "$ICON_TMP" -o "$APP_DIR/Contents/Resources/AppIcon.icns" ||
    echo "    (icon generation skipped)"
fi

# ------------------------------------------------------------- Info.plist ---
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>MacManager</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>$DEPLOY_TARGET</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <!-- Finder is used as the fallback when moving an administrator-owned
         item to the Trash; macOS asks the user to approve this once. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Mac Manager asks Finder to move administrator-owned files to the Trash.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Mac Manager measures folder sizes to show where your disk space went.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Mac Manager measures folder sizes to show where your disk space went.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Mac Manager measures your Downloads folder to show where your disk space went.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# --------------------------------------------------------------- codesign ---
# An ad-hoc signature keeps the app's identity stable across rebuilds, so the
# permissions macOS grants it are not re-prompted every time.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "    (signing skipped)"

echo ""
echo "==> Built $APP_DIR"
echo "    Run it:      open \"$APP_DIR\""
echo "    Install it:  cp -R \"$APP_DIR\" /Applications/"
