#!/bin/sh
# Copies the shared YL conformance vectors from the hub repo (yuigui) into
# this package's test bundle, so the app repo builds and tests without
# yuigui checked out. Run after any change to yuigui/spec/conformance.
#   Packages/YuiLines/scripts/sync-vectors.sh [path/to/yuigui/spec/conformance]
set -eu
pkg=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-"$pkg/../../../yuigui/spec/conformance"}
dst="$pkg/Tests/YuiLinesTests/Resources/conformance"
[ -d "$src" ] || { echo "sync-vectors: no vectors at $src" >&2; exit 1; }
mkdir -p "$dst"
rm -f "$dst"/[0-9][0-9]-*.json
cp "$src"/[0-9][0-9]-*.json "$dst"/
echo "sync-vectors: $(ls "$dst"/[0-9][0-9]-*.json | wc -l | tr -d ' ') files from $src"
