#!/bin/bash
# Archive Yui and upload to TestFlight with the App Store Connect API key.
# Needs: YUI_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID in ~/.appstoreconnect/yui.env,
# key at ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.appstoreconnect/yui.env
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer YUI_TEAM_ID
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
BUILD=$(git rev-list --count HEAD)
# App Store Connect can be ahead of the commit count (rebuilds of one commit):
# never reuse a build number, it fails the upload as a timeout.
LATEST=$(python3 scripts/asc.py GET "/v1/builds?filter[app]=6815454240&sort=-uploadedDate&limit=50&fields[builds]=version" 2>/dev/null \
  | python3 -c 'import json,sys; print(max([int(b["attributes"]["version"]) for b in json.load(sys.stdin)["data"]] or [0]))' 2>/dev/null || echo 0)
[ "${LATEST:-0}" -ge "$BUILD" ] 2>/dev/null && BUILD=$((LATEST + 1))
BUILD=${YUI_BUILD:-$BUILD}

xcodegen generate --quiet
rm -rf build && mkdir build
xcodebuild -project Yui.xcodeproj -scheme Yui -destination 'generic/platform=iOS' \
  -archivePath build/Yui.xcarchive CURRENT_PROJECT_VERSION="$BUILD" $(scripts/build_stamp.sh) "${AUTH[@]}" archive | tail -5
# Keep this build's dSYMs (YUI-102): yui_perf_report.py symbolicates hang and
# crash stacks against them after build/ is gone.
mkdir -p ~/.yui-dsyms/"$BUILD" && cp -R build/Yui.xcarchive/dSYMs/. ~/.yui-dsyms/"$BUILD"/ 2>/dev/null || true
cat > build/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${YUI_TEAM_ID}</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Yui.xcarchive -exportOptionsPlist build/export.plist \
  -exportPath build/export "${AUTH[@]}" | tail -5
echo "uploaded build $BUILD"

# Public TestFlight: add the build to the "Public" group and submit it for beta
# review. It is usually still processing here; the yui-testflight-watch cron
# runs the same step every 10 minutes and finishes the job once it is VALID.
python3 scripts/testflight_public.py --build "$BUILD" || true
