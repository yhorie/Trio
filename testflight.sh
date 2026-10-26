#!/usr/bin/env bash
# Archive Trio and (optionally) upload it to TestFlight. Modelled on yoitv/apple/testflight.sh as described in
# ~/repo/dotfiles/IOS-RELEASE.md, adapted for Trio:
#   - no xcodegen: Trio ships a checked-in Trio.xcworkspace
#   - the build number is taken from App Store Connect (latest + 1), like Trio's fastlane
#   - Thread Sanitizer is forced off (the shared scheme enables it for Run)
#
# Usage:
#   ./testflight.sh                     # archive + export an .ipa locally, no upload
#   UPLOAD=1 ./testflight.sh            # archive + upload to App Store Connect
#   UPLOAD_EXISTING=1 ./testflight.sh   # upload the archive a previous run left, no rebuild
#
# TRIO_DIR selects the checkout to build (default: this script's directory).
# Every successful upload is recorded in $STATE_DIR/last-upload for trio-autobuild.sh.
set -euo pipefail

SCHEME="${SCHEME:-Trio}"
BUNDLE="${BUNDLE:-org.nightscout.GNZ9M9P5MZ.trio}"
TEAM="${TEAM:-GNZ9M9P5MZ}"
UPLOAD="${UPLOAD:-0}"
UPLOAD_EXISTING="${UPLOAD_EXISTING:-0}"
STATE_DIR="${STATE_DIR:-$HOME/Library/Application Support/trio-autobuild}"

cd "${TRIO_DIR:-$(dirname "$0")}"
source ~/.appstoreconnect/env
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
OUT="build/testflight"
ARCHIVE="$OUT/Trio.xcarchive"
mkdir -p "$OUT" "$STATE_DIR"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

asc() {  # asc <python snippet using get(path, **query)>
  uv run -q --with pyjwt --with cryptography python - "$@" <<EOF
import os, sys, time, json, urllib.request, urllib.parse, jwt
key = open("$KEY_PATH").read()
def tok():
    now = int(time.time())
    return jwt.encode({"iss": "$ASC_ISSUER_ID", "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": "$ASC_KEY_ID", "typ": "JWT"})
def get(path, **q):
    url = "https://api.appstoreconnect.apple.com" + path + ("?" + urllib.parse.urlencode(q) if q else "")
    return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer " + tok()})))
$1
EOF
}

APP_ID=$(asc "
apps = get('/v1/apps', **{'filter[bundleId]': '$BUNDLE'})['data']
print(apps[0]['id'] if apps else '')")
if [[ -z "$APP_ID" ]]; then
  echo "No App Store Connect app record for $BUNDLE. Create it first (see the plan)." >&2
  exit 1
fi

LAST=$(asc "
b = get('/v1/builds', **{'filter[app]': '$APP_ID', 'sort': '-uploadedDate', 'limit': 50})['data']
print(max([int(x['attributes']['version']) for x in b] or [0]))")

if [[ "$UPLOAD_EXISTING" == 1 ]]; then
  [[ -d "$ARCHIVE" && -f "$OUT/commit" ]] || { echo "No archive to upload in $PWD/$OUT" >&2; exit 1; }
  APP_PLIST="$ARCHIVE/Products/Applications/Trio.app/Info.plist"
  VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST")
  BUILD=$(plutil -extract CFBundleVersion raw "$APP_PLIST")
  if (( BUILD <= LAST )); then
    echo "Archive is build $BUILD but App Store Connect already has $LAST; rebuild it." >&2
    exit 1
  fi
  UPLOAD=1
  echo "==> Uploading existing archive $VERSION ($BUILD) from $(cut -c1-9 "$OUT/commit")"
else
  BUILD=$((LAST + 1))
  # The watch app and extensions hardcode MARKETING_VERSION = 1.0; App Store Connect
  # rejects a watch app whose version differs from the iOS app's, so stamp all targets.
  VERSION=$(awk -F' *= *' '/^APP_VERSION/{print $2}' Config.xcconfig)
  echo "==> $BUNDLE: last build $LAST, archiving $VERSION ($BUILD)"

  # A failed archive must not fall back to the previous run's archive or .ipa.
  rm -rf "$ARCHIVE" "$OUT/export" "$OUT/commit"
  xcodebuild archive \
    -workspace Trio.xcworkspace -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    "${AUTH[@]}" \
    DEVELOPER_TEAM="$TEAM" APP_BUILD_NUMBER="$BUILD" CURRENT_PROJECT_VERSION="$BUILD" \
    MARKETING_VERSION="$VERSION" \
    ENABLE_THREAD_SANITIZER=NO ENABLE_ADDRESS_SANITIZER=NO \
    | tee "$OUT/archive.log" | grep -E "error:|\*\* ARCHIVE" || true
  [[ -d "$ARCHIVE" ]] || { echo "Archive failed, see $PWD/$OUT/archive.log" >&2; exit 1; }
  echo "${BUILD_ID:-$(git rev-parse HEAD)}" > "$OUT/commit"  # trio-autobuild.sh passes upstream:patch-id
fi

# Fail here, not at upload validation, if any bundle's version or build disagrees.
while IFS= read -r -d '' b; do
  v=$(plutil -extract CFBundleShortVersionString raw "$b/Info.plist")
  n=$(plutil -extract CFBundleVersion raw "$b/Info.plist")
  if [[ "$v" != "$VERSION" || "$n" != "$BUILD" ]]; then
    echo "Version mismatch in ${b#"$ARCHIVE"/}: $v ($n), expected $VERSION ($BUILD)" >&2
    exit 1
  fi
done < <(find "$ARCHIVE/Products/Applications" \( -name '*.app' -o -name '*.appex' \) -print0)

DEST=$([[ "$UPLOAD" == 1 ]] && echo upload || echo export)
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

echo "==> exportArchive (destination: $DEST)"
rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" \
  | tee "$OUT/export.log" | grep -E "error:|\*\* EXPORT|Upload" || true

grep -q '\*\* EXPORT SUCCEEDED \*\*' "$OUT/export.log" || { echo "Export failed, see $PWD/$OUT/export.log" >&2; exit 1; }

if [[ "$UPLOAD" != 1 ]]; then
  echo "==> Exported $(ls "$OUT/export"/*.ipa). Not uploaded (run with UPLOAD=1)."
else
  echo "$(cat "$OUT/commit") $(date +%s) $VERSION $BUILD" > "$STATE_DIR/last-upload"
  echo "==> Uploaded $VERSION ($BUILD). It appears in TestFlight once Apple finishes processing."
fi
