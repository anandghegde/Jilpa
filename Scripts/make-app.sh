#!/bin/bash
# Release pipeline: build a SwiftPM executable for arm64, wrap it in an .app bundle, sign it with
# Developer ID and the hardened runtime, and optionally notarize and staple it. Produces
# dist/<Name>.app and dist/<Name>-<version>.zip.
#
# Defaults build Jilpa.app. The same script builds the Spike 0 logger agent and JilpaDemo.app by
# pointing --product, --name, --plist and --entitlements somewhere else.
#
# One-time setup for --notarize:
#   xcrun notarytool store-credentials jilpa-notary --apple-id <id> --team-id <team> --password <app-specific>

set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT=JilpaAgent
NAME=Jilpa
PLIST=App/Info.plist
ENTITLEMENTS=App/Jilpa.entitlements
SIGN=developer-id
NOTARIZE=0
PROFILE="${JILPA_NOTARY_PROFILE:-jilpa-notary}"
VERSION=""
BUNDLE_ID=""
EMBED=""

usage() {
  cat <<'EOF'
usage: Scripts/make-app.sh [options]

  --product <name>        SwiftPM executable product            (default JilpaAgent)
  --name <name>           Bundle name, without .app             (default Jilpa)
  --plist <path>          Info.plist to embed                   (default App/Info.plist)
  --entitlements <path>   Entitlements file, or "none"          (default App/Jilpa.entitlements)
  --bundle-id <id>        Override CFBundleIdentifier
  --version <x.y.z>       Override CFBundleShortVersionString
  --sign <how>            developer-id | adhoc | "<identity>"   (default developer-id)
  --notarize              Submit to the notary service, wait, staple and assess
  --profile <name>        notarytool keychain profile           (default jilpa-notary)
  --embed <app>           Put an already built helper app in Contents/Helpers and sign it
                          with the same identity. Onboarding's demo:
                            Scripts/make-app.sh --product FixtureApp --name JilpaDemo \
                              --plist App/Demo/Info.plist --entitlements none --sign adhoc
                            Scripts/make-app.sh --embed dist/JilpaDemo.app --sign adhoc
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --plist) PLIST="$2"; shift 2 ;;
    --entitlements) ENTITLEMENTS="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --sign) SIGN="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --embed) EMBED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option $1" >&2; usage >&2; exit 64 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

if [ "$NOTARIZE" = 1 ] && [ "$SIGN" = adhoc ]; then
  echo "an ad hoc signature cannot be notarized" >&2
  exit 64
fi

case "$SIGN" in
  adhoc) IDENTITY="-" ;;
  developer-id)
    IDENTITY=$(security find-identity -v -p codesigning |
      sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "(Developer ID Application: [^"]+)"$/\1/p' | head -1)
    if [ -z "$IDENTITY" ]; then
      echo "no Developer ID Application identity in the keychain; use --sign adhoc for a local build" >&2
      exit 1
    fi
    ;;
  *) IDENTITY="$SIGN" ;;
esac

step "Building $PRODUCT (release, arm64)"
swift build -c release --arch arm64 --product "$PRODUCT"
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

APP="dist/$NAME.app"
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP/Contents/Info.plist"; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ -n "$VERSION" ] && plist_set CFBundleShortVersionString "$VERSION"
[ -n "$BUNDLE_ID" ] && plist_set CFBundleIdentifier "$BUNDLE_ID"
VERSION=$(plist_get CFBundleShortVersionString)
EXECUTABLE=$(plist_get CFBundleExecutable)
cp "$BIN_DIR/$PRODUCT" "$APP/Contents/MacOS/$EXECUTABLE"
if [ -n "$EMBED" ]; then
  [ -d "$EMBED" ] || { echo "no helper app at $EMBED" >&2; exit 1; }
  mkdir -p "$APP/Contents/Helpers"
  ditto "$EMBED" "$APP/Contents/Helpers/$(basename "$EMBED")"
fi

step "Signing as ${IDENTITY/#-/ad hoc}"
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
if [ "$SIGN" = adhoc ]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi
# A helper is signed first, inside out, with the identity and runtime of the outer app and none
# of its entitlements: the demo needs none, and a nested app is never signed by --deep.
if [ -n "$EMBED" ]; then
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/$(basename "$EMBED")"
fi
[ "$ENTITLEMENTS" != none ] && SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="dist/$NAME-$VERSION.zip"
make_zip() {
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
}
step "Zipping to $ZIP"
make_zip

if [ "$NOTARIZE" = 1 ]; then
  step "Notarizing with keychain profile $PROFILE"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  step "Stapling"
  xcrun stapler staple "$APP"
  make_zip
  step "Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$APP"
fi

step "Done: $ZIP"
