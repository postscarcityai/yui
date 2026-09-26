#!/bin/bash
# Test build by link (YUI-55): archive origin/main as an ad hoc build, host it
# privately and send a tap-to-install card into the yui agent's thread. It
# installs as "Yui Dev" (com.yuigui.app.dev, YUI-91) beside TestFlight Yui.
# No TestFlight, no upload limit. Ad hoc builds install only on devices
# registered to the developer account, so the link works on the owner's phone
# and nowhere else.
#
#   scripts/devbuild.sh            build if main moved and the last link is 3h old
#   scripts/devbuild.sh --force    build now (someone asked for one)
#   scripts/devbuild.sh --no-send  build and host, print the link, send nothing
#
# Always builds a clean worktree of origin/main, never the working tree.
# Needs: ~/.appstoreconnect/yui.env + the ASC key (like testflight.sh), a
# Supabase access token (SUPABASE_ACCESS_TOKEN or the CLI's keychain entry),
# xcodegen, and `hermes` for the send. Prints one line per step; silent (exit 0)
# when there is nothing new to build.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
STATE=${YUI_DEVBUILD_DIR:-$HOME/.yui-devbuild}
PROFILE=${YUI_DEVBUILD_PROFILE:-yui}
GAP=${YUI_DEVBUILD_GAP:-10800}   # at most one automatic link per 3 hours
FORCE=0 SEND=1
for a in "$@"; do
  case $a in
    --force) FORCE=1 ;;
    --no-send) SEND=0 ;;
    *) echo "usage: $0 [--force] [--no-send]" >&2; exit 2 ;;
  esac
done
mkdir -p "$STATE"
# One build at a time (a lock older than 2 hours is a dead run's).
if ! mkdir "$STATE/lock" 2>/dev/null; then
  [ -z "$(find "$STATE/lock" -maxdepth 0 -mmin +120)" ] && { echo "another dev build is running"; exit 0; }
fi
trap 'rmdir "$STATE/lock" 2>/dev/null' EXIT

source ~/.appstoreconnect/yui.env
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} YUI_TEAM_ID
KEY=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

git -C "$REPO" fetch -q origin main
SHA=$(git -C "$REPO" rev-parse origin/main)
LAST_SHA=$(cat "$STATE/last_sha" 2>/dev/null || true)
LAST_AT=$(cat "$STATE/last_at" 2>/dev/null || echo 0)
if [ $FORCE = 0 ]; then
  [ "$SHA" = "$LAST_SHA" ] && exit 0
  [ $(( $(date +%s) - LAST_AT )) -lt "$GAP" ] && exit 0
  # Only app changes are worth a build (not docs, scripts or the backend).
  if [ -n "$LAST_SHA" ] && [ -z "$(git -C "$REPO" diff --name-only "$LAST_SHA" "$SHA" -- Yui YuiWidgets Shared Packages project.yml 2>/dev/null)" ]; then
    echo "$SHA" > "$STATE/last_sha"; exit 0
  fi
fi

# Build number <commit count>.<n>: never collides with a TestFlight number.
COUNT=$(git -C "$REPO" rev-list --count "$SHA")
N=$(( $(grep -c "^$COUNT\." "$STATE/history" 2>/dev/null || true) + 1 ))
BUILD="$COUNT.$N"

WT="$STATE/wt"
git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
git -C "$REPO" worktree prune
git -C "$REPO" worktree add -q --detach "$WT" "$SHA"
cd "$WT"
echo "building $BUILD from ${SHA:0:7}"
# Yui Dev (YUI-91): its own bundle id, name and icon, so it installs next to
# TestFlight Yui instead of being refused as "already installed". Only this
# worktree's project.yml changes. Starts with its own empty data; the backend
# takes its Sign in with Apple and push topic (<bundle>.dev).
python3 - <<'PY'
import re
p = "project.yml"; s = open(p).read()
subs = [(r"(PRODUCT_BUNDLE_IDENTIFIER: )com\.yuigui\.app\n", r"\1com.yuigui.app.dev\n", 1),
        (r"(PRODUCT_BUNDLE_IDENTIFIER: )com\.yuigui\.app\.widgets\n", r"\1com.yuigui.app.dev.widgets\n", 1),
        (r"(CFBundleURLName: )com\.yuigui\.app\n", r"\1com.yuigui.app.dev\n", 1),
        (r"(CFBundleDisplayName: )Yui\n", r"\1Yui Dev\n", 2)]
for pat, rep, want in subs:
    s, n = re.subn(pat, rep, s)
    if n != want:
        raise SystemExit(f"project.yml: {pat} matched {n}, want {want}")
open(p, "w").write(s)
PY
swift "$REPO/scripts/devbuild_icon.swift" Yui/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
xcodegen generate --quiet
rm -rf build && mkdir build
xcodebuild -project Yui.xcodeproj -scheme Yui -destination 'generic/platform=iOS' \
  -archivePath build/Yui.xcarchive CURRENT_PROJECT_VERSION="$BUILD" $(scripts/build_stamp.sh) "${AUTH[@]}" archive > build/archive.log 2>&1 \
  || { tail -20 build/archive.log; exit 1; }
# Keep this build's dSYMs (YUI-102): yui_perf_report.py symbolicates hang and
# crash stacks against them after build/ is gone.
mkdir -p ~/.yui-dsyms/"$BUILD" && cp -R build/Yui.xcarchive/dSYMs/. ~/.yui-dsyms/"$BUILD"/ 2>/dev/null || true
# release-testing = ad hoc: signed for the registered devices, production APNs
# like TestFlight, so pushes keep working.
cat > build/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${YUI_TEAM_ID}</string>
  <key>compileBitcode</key><false/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Yui.xcarchive -exportOptionsPlist build/export.plist \
  -exportPath build/export "${AUTH[@]}" > build/export.log 2>&1 || { tail -20 build/export.log; exit 1; }
IPA=$(ls build/export/*.ipa)
echo "exported $(basename "$IPA") ($(du -h "$IPA" | cut -f1))"

# What changed since the last dev build (or the last 5 commits the first time).
RANGE=${LAST_SHA:+$LAST_SHA..$SHA}
git log --no-merges --format='%s' ${RANGE:--5 $SHA} -- Yui YuiWidgets Shared Packages project.yml > build/changes.txt || true

python3 "$WT/scripts/devbuild_publish.py" --ipa "$IPA" --build "$BUILD" --sha "$SHA" \
  --changes build/changes.txt --out build/link.json $([ $SEND = 1 ] && echo --send "$PROFILE")

echo "$SHA" > "$STATE/last_sha"
date +%s > "$STATE/last_at"
echo "$BUILD $SHA $(date +%FT%T)" >> "$STATE/history"
cp build/link.json "$STATE/last_link.json"
cd "$REPO" && git worktree remove --force "$WT"
