#!/bin/zsh
# Builds the app and wraps it into build/<APP_NAME>.app.
#
# Environment:
#   APP_NAME       Display/bundle name             (default: Explorer)
#   BUNDLE_ID      CFBundleIdentifier              (default: com.example.explorer — change before shipping)
#   VERSION        CFBundleShortVersionString      (default: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion                 (default: 1)
#   CONFIG         debug | release                 (default: release)
#   SIGN_IDENTITY  codesign identity; "-" = ad-hoc (default: -)
#                  e.g. "Developer ID Application: Your Name (TEAMID)" for distribution
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="${APP_NAME:-Explorer}"
BUNDLE_ID="${BUNDLE_ID:-com.example.explorer}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product ExplorerApp
bin_dir="$(swift build -c "$CONFIG" --show-bin-path)"

app="build/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/ExplorerApp" "$app/Contents/MacOS/$APP_NAME"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
</dict>
</plist>
PLIST

sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    # Hardened runtime + secure timestamp are required for notarization.
    sign_args+=(--options runtime --timestamp)
fi
codesign "${sign_args[@]}" "$app"

echo "Built $app"
