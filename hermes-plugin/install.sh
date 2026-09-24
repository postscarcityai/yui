#!/bin/bash
# Install the yui platform plugin into one Hermes profile and turn the Yui
# channel on for it. Plugins load from the PROFILE's home
# (~/.hermes/profiles/<p>/plugins), so each profile that talks in Yui needs this.
#
#   hermes-plugin/install.sh yui          # then: hermes -p yui gateway restart
#
# Symlinks, so a git pull updates every installed profile. Touches only the
# profile's plugins dir and two config keys (plugins.enabled, platforms.yui).
# A profile with no Yui agent of its own still gets handoffs ("send it to
# Yui", /yui on Telegram): they land in the user's first agent's thread.
set -euo pipefail
P="${1:?usage: install.sh <hermes profile>}"
SRC="$(cd "$(dirname "$0")" && pwd)/yui"
if [ "$P" = default ]; then HOME_DIR="$HOME/.hermes"; else HOME_DIR="$HOME/.hermes/profiles/$P"; fi
[ -f "$HOME_DIR/config.yaml" ] || { echo "no Hermes profile '$P' at $HOME_DIR" >&2; exit 1; }
python3 "$(dirname "$0")/sync_channel.py" --check >/dev/null || echo "note: bundled CHANNEL.md is stale, run sync_channel.py" >&2
mkdir -p "$HOME_DIR/plugins"
ln -sfn "$SRC" "$HOME_DIR/plugins/yui"
# Direct YAML edit: `hermes plugins enable` waits on an interactive prompt.
"$HOME/.hermes/hermes-agent/venv/bin/python" - "$HOME_DIR/config.yaml" "$P" <<'PY'
import sys
from ruamel.yaml import YAML  # round-trip: keeps the profile's comments and layout
y = YAML()
y.preserve_quotes = True
y.indent(mapping=2, sequence=4, offset=2)
p = sys.argv[1]
cfg = y.load(open(p)) or {}
plugins = cfg.setdefault("plugins", {})
enabled = plugins.setdefault("enabled", [])
if "yui" not in enabled:
    enabled.append("yui")
yui = cfg.setdefault("platforms", {}).setdefault("yui", {})
yui["enabled"] = True
# Home channel = this profile: send_message(target="yui") with no chat id
# lands in its own Yui thread, or the user's first agent if it has none.
yui.setdefault("home_channel", {"platform": "yui", "chat_id": sys.argv[2], "name": "Yui"})
with open(p, "w") as f:
    y.dump(cfg, f)
PY
echo "installed yui plugin in profile $P ($HOME_DIR/plugins/yui -> $SRC)"
echo "next: hermes -p $P yui status   and   hermes -p $P gateway restart"
