#!/bin/zsh
# Notarizes and staples a Developer ID–signed app produced by bundle.sh.
#
# One-time setup (stores credentials in the keychain):
#   xcrun notarytool store-credentials explorer-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/bundle.sh
#   scripts/notarize.sh [path/to/App.app]
#
# Environment:
#   NOTARY_PROFILE  keychain profile name (default: explorer-notary)
set -euo pipefail
cd "${0:A:h}/.."

app="${1:-build/${APP_NAME:-Explorer}.app}"
profile="${NOTARY_PROFILE:-explorer-notary}"

if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: $app is ad-hoc signed; rebuild with SIGN_IDENTITY set to a Developer ID identity" >&2
    exit 1
fi

zip="build/$(basename "$app" .app)-notarize.zip"
ditto -c -k --keepParent "$app" "$zip"

xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

rm -f "$zip"
echo "Notarized $app"
