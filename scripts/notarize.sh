#!/bin/zsh
# Notarizes and staples a Developer ID–signed app (from bundle.sh) or disk image (from dmg.sh).
#
# One-time setup (stores credentials in the keychain):
#   xcrun notarytool store-credentials explorer-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/bundle.sh
#   scripts/notarize.sh [path/to/App.app | path/to/App.dmg]
#
# Environment:
#   NOTARY_PROFILE  keychain profile name (default: explorer-notary)
set -euo pipefail
cd "${0:A:h}/.."

app="${1:-build/${APP_NAME:-Panes}.app}"
profile="${NOTARY_PROFILE:-explorer-notary}"

if ! codesign -dv "$app" >/dev/null 2>&1 || codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: $app is unsigned or ad-hoc signed; rebuild with SIGN_IDENTITY set to a Developer ID identity" >&2
    exit 1
fi

if [[ "$app" == *.dmg ]]; then
    # A signed disk image is submitted as is.
    xcrun notarytool submit "$app" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
    spctl --assess --type open --context context:primary-signature --verbose "$app"
else
    zip="build/$(basename "$app" .app)-notarize.zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
    rm -f "$zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose "$app"
fi

echo "Notarized $app"
