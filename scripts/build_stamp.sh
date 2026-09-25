#!/bin/bash
# Build settings that stamp this checkout into Info.plist (YUI-92): short commit
# sha, UTC build time, and the channel guide version the plugin bundles. Settings
# > About this build shows them. Prints NAME=value words for xcodebuild:
#   xcodebuild ... $(scripts/build_stamp.sh) archive
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SHA=$(git -C "$REPO" rev-parse --short=7 HEAD)
# The first line of the bundled guide: <!-- yui-channel-guide v19+1259f8ed ... -->
GUIDE=$(head -1 "$REPO/hermes-plugin/yui/CHANNEL.md" | sed -nE 's/.*yui-channel-guide (v[0-9.]+).*/\1/p')
echo "YUI_COMMIT=$SHA YUI_BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) YUI_CHANNEL_GUIDE=${GUIDE}"
