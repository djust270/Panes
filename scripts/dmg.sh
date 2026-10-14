#!/bin/zsh
# Packages build/<APP_NAME>.app into build/<APP-NAME>-<VERSION>.dmg (spaces become hyphens:
# GitHub renames release assets with spaces): the app beside an Applications shortcut,
# compressed, and signed when SIGN_IDENTITY is a real identity.
#
# Usage: VERSION=0.2.0 scripts/dmg.sh [path/to/App.app]
set -euo pipefail
cd "${0:A:h}/.."

APP_NAME="${APP_NAME:-Panes}"
VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
app="${1:-build/$APP_NAME.app}"
dmg="build/${APP_NAME// /-}-$VERSION.dmg"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$dmg"
fi
hdiutil verify -quiet "$dmg"
echo "Built $dmg"
