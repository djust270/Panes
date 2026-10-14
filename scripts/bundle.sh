#!/bin/zsh
# Builds the app and wraps it into build/<APP_NAME>.app.
#
# Environment:
#   APP_NAME       Display/bundle name             (default: Panes)
#   BUNDLE_ID      CFBundleIdentifier              (default: co.justgeeks.explorer)
#   VERSION        CFBundleShortVersionString      (default: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion                 (default: 1) — must increase with every release,
#                  betas included: Sparkle compares it to decide what's newer
#   CONFIG         debug | release                 (default: release)
#   SIGN_IDENTITY  codesign identity; "-" = ad-hoc (default: -)
#                  e.g. "Developer ID Application: Your Name (TEAMID)" for distribution
#   REPO_URL       GitHub repository, for issues   (default: https://github.com/djust270/osx-explorer)
#   SU_FEED_URL    Sparkle appcast URL             (default: appcast.xml on the repository's main branch)
#   SU_PUBLIC_KEY  Sparkle EdDSA public key        (default: contents of scripts/sparkle-public-key.txt)
#                  Updates are off in builds without a feed URL or key.
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="${APP_NAME:-Panes}"
BUNDLE_ID="${BUNDLE_ID:-co.justgeeks.explorer}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
REPO_URL="${REPO_URL:-https://github.com/djust270/osx-explorer}"
SU_FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/djust270/osx-explorer/main/appcast.xml}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-$(cat scripts/sparkle-public-key.txt 2>/dev/null || true)}"

swift build -c "$CONFIG" --product ExplorerApp --disable-keychain
bin_dir="$(swift build -c "$CONFIG" --show-bin-path)"

app="build/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin_dir/ExplorerApp" "$app/Contents/MacOS/$APP_NAME"
# SwiftPM links Sparkle from beside the binary (@loader_path); in the bundle it's in Frameworks.
ditto "$bin_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/$APP_NAME" 2>/dev/null

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
    <key>NSHumanReadableCopyright</key>   <string>© $(date +%Y) David Just</string>
    <key>ExplorerRepositoryURL</key>      <string>$REPO_URL</string>
    <!-- Sparkle: daily checks (the user can turn them off in Settings). -->
    <key>SUFeedURL</key>                  <string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key>              <string>$SU_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>    <true/>
    <key>SUScheduledCheckInterval</key>   <integer>86400</integer>
    <!-- Opens folders (listed under Open With; can be made the default in Settings). -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>       <string>Folder</string>
            <key>CFBundleTypeRole</key>       <string>Viewer</string>
            <key>LSHandlerRank</key>          <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string><string>public.volume</string></array>
        </dict>
    </array>
    <!-- Services menu: Open in <app> (folders), Reveal in <app> (anything). -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>       <dict><key>default</key><string>Open in $APP_NAME</string></dict>
            <key>NSMessage</key>        <string>openInExplorer</string>
            <key>NSPortName</key>       <string>$APP_NAME</string>
            <key>NSRequiredContext</key> <dict/>
            <key>NSSendFileTypes</key>  <array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>       <dict><key>default</key><string>Reveal in $APP_NAME</string></dict>
            <key>NSMessage</key>        <string>revealInExplorer</string>
            <key>NSPortName</key>       <string>$APP_NAME</string>
            <key>NSRequiredContext</key> <dict/>
            <key>NSSendFileTypes</key>  <array><string>public.item</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    # Hardened runtime + secure timestamp are required for notarization.
    sign_args+=(--options runtime --timestamp)
fi
# Inside out: Sparkle's helpers, the framework, then the app (no --deep; Sparkle's docs advise against it).
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${sign_args[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$sparkle/Autoupdate"
codesign "${sign_args[@]}" "$sparkle/Updater.app"
codesign "${sign_args[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"

echo "Built $app"
