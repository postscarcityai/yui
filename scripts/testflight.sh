#!/bin/bash
# Archive Yui and upload to TestFlight with the App Store Connect API key.
# Needs: YUI_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID in ~/.appstoreconnect/yui.env,
# key at ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
#
# One upload per 24 h. Exits 3 if the newest build was uploaded less than 24 h
# ago, unless --hotfix "<reason>" is passed. Hotfix reasons: crash, data loss,
# sign-in blocker, or "Chris asked for a build". Nothing else. The reason is printed for the ship card.
# --daily is for the 06:00 cron (yui-daily-release): one upload per calendar day
# (America/New_York), so a build that went up at 12:25 yesterday does not block
# 06:00 today. The 24 h rule stays for everything else.
set -euo pipefail
HOTFIX=""
DAILY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hotfix) HOTFIX="${2:-}"; [ -n "$HOTFIX" ] || { echo "--hotfix needs a reason" >&2; exit 2; }; shift 2 ;;
    --daily) DAILY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
cd "$(dirname "$0")/.."
source ~/.appstoreconnect/yui.env
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer YUI_TEAM_ID
# 24 h guard: newest build's uploadedDate via asc.py.
AGE=$(python3 scripts/asc.py GET "/v1/builds?filter[app]=6815454240&sort=-uploadedDate&limit=1&fields[builds]=uploadedDate,version" 2>/dev/null \
  | python3 -c 'import json,sys,datetime as d; b=json.load(sys.stdin)["data"]
print(int((d.datetime.now(d.timezone.utc)-d.datetime.fromisoformat(b[0]["attributes"]["uploadedDate"])).total_seconds()) if b else 999999999)' 2>/dev/null || echo "")
if [ -z "$AGE" ]; then
  [ -n "$HOTFIX" ] || { echo "testflight guard: could not read the newest build's uploadedDate from App Store Connect. Refusing. Pass --hotfix \"<reason>\" to override." >&2; exit 4; }
elif [ "$DAILY" = 1 ] && [ -z "$HOTFIX" ]; then
  SINCE_MIDNIGHT=$(TZ=America/New_York date +'%H %M %S' | awk '{print $1*3600+$2*60+$3}')
  if [ "$AGE" -lt "$SINCE_MIDNIGHT" ]; then
    echo "testflight guard: a build already went up today (${AGE}s ago). One upload per day." >&2
    exit 3
  fi
elif [ "$AGE" -lt 86400 ]; then
  if [ -z "$HOTFIX" ]; then
    echo "testflight guard: newest build was uploaded $((AGE/3600))h$(((AGE%3600)/60))m ago. One upload per 24 h. Wait $(((86400-AGE)/3600))h$((((86400-AGE)%3600)/60))m, or pass --hotfix \"<reason>\" (crash, data loss, sign-in blocker only)." >&2
    exit 3
  fi
fi
[ -z "$HOTFIX" ] || echo "HOTFIX upload (bypassing the 24 h guard): $HOTFIX"
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
