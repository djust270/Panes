#!/bin/zsh
# Builds a release: app → notarized → DMG → notarized → Sparkle-signed → appcast item, and
# with PUBLISH=1 a GitHub release plus the updated appcast.xml pushed to main.
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh 0.2.0 7          # stable
#   SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh 0.3.0-beta.1 8   # beta channel
#   PUBLISH=1 SIGN_IDENTITY=… scripts/release.sh 0.2.0 7
#   DRY_RUN=1 scripts/release.sh 0.2.0 7      # ad-hoc signed, no notarization, appcast written to build/
#
# The build number must increase with every release, betas included. A version containing
# "beta" goes to the beta channel (Settings › Get beta updates).
#
# Needs: the Sparkle signing key in the login keychain (generate_keys; back it up with
# `generate_keys -x file`), a notarytool profile (see notarize.sh), and `gh` for PUBLISH.
set -euo pipefail
cd "${0:A:h}/.."

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/release.sh <version> <build-number>" >&2
    exit 64
fi
export VERSION="$1" BUILD_NUMBER="$2"
export APP_NAME="${APP_NAME:-Panes}"
REPO="${REPO:-djust270/osx-explorer}"
DRY_RUN="${DRY_RUN:-0}"
PUBLISH="${PUBLISH:-0}"
tag="v$VERSION"
channel=""
[[ "$VERSION" == *beta* ]] && channel="beta"

if [[ "$DRY_RUN" == 1 ]]; then
    export SIGN_IDENTITY="-"
    [[ "$PUBLISH" == 1 ]] && { echo "error: DRY_RUN and PUBLISH don't mix" >&2; exit 64; }
elif [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
    echo "error: set SIGN_IDENTITY to a Developer ID Application identity (or DRY_RUN=1)" >&2
    exit 64
fi
if [[ "$PUBLISH" == 1 && -n "$(git status --porcelain)" ]]; then
    echo "error: commit your changes first; PUBLISH commits appcast.xml on its own" >&2
    exit 1
fi

CONFIG=release scripts/bundle.sh
[[ "$DRY_RUN" == 1 ]] || scripts/notarize.sh "build/$APP_NAME.app"
scripts/dmg.sh "build/$APP_NAME.app"
dmg="build/${APP_NAME// /-}-$VERSION.dmg"
[[ "$DRY_RUN" == 1 ]] || scripts/notarize.sh "$dmg"

# EdDSA signature over the final (stapled) DMG, with the key from the keychain.
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$dmg")"

appcast="appcast.xml"
if [[ "$DRY_RUN" == 1 ]]; then
    appcast="build/appcast.xml"
    [[ -f appcast.xml ]] && cp appcast.xml "$appcast"
fi
python3 -I scripts/appcast.py --appcast "$appcast" \
    --version "$VERSION" --build "$BUILD_NUMBER" \
    --url "https://github.com/$REPO/releases/download/$tag/$(basename "$dmg")" \
    --notes-url "https://github.com/$REPO/releases/tag/$tag" \
    --signature "$signature" ${channel:+--channel "$channel"}

if [[ "$PUBLISH" == 1 ]]; then
    gh release create "$tag" "$dmg" --repo "$REPO" --title "$APP_NAME $VERSION" --generate-notes \
        ${channel:+--prerelease}
    git add appcast.xml
    git commit -m "Appcast: $APP_NAME $VERSION ($BUILD_NUMBER)"
    git push
    echo "Published $tag"
else
    echo "Built $dmg and $appcast. Publish with PUBLISH=1."
fi
