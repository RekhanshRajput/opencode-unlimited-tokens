#!/usr/bin/env bash
# Remove the token-guard plugin and helpers. Handoffs, logs, and backups stay.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/token-guard"
BIN_DIR="$HOME/.local/bin"
CFG="$CONFIG_DIR/opencode.json"

say() { printf '%s\n' "$*"; }

rm -rf "$PLUGIN_DIR"
say "Removed $PLUGIN_DIR"

for file in "$BIN_DIR/oc-auto-reinstall" "$BIN_DIR/oc-safe-reinstall"; do
  if [ -e "$file" ]; then
    rm -f "$file"
    say "Removed $file"
  fi
done

if [ -f "$CFG" ] && command -v node >/dev/null 2>&1; then
  backup="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$backup"
  say "Config backup: $backup"

  cleanup_script="$(mktemp)"
  trap 'rm -f "$cleanup_script"' EXIT
  cat >"$cleanup_script" <<'NODE'
const fs = require("fs")
const [cfgPath, pluginPath] = process.argv.slice(2)
const raw = fs.readFileSync(cfgPath, "utf8").trim()
const cfg = raw ? JSON.parse(raw) : {}
if (Array.isArray(cfg.plugins)) {
  cfg.plugins = cfg.plugins.filter(
    (entry) => (typeof entry === "string" ? entry : entry && entry.package) !== pluginPath,
  )
  if (cfg.plugins.length === 0) delete cfg.plugins
}
fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n")
NODE
  node "$cleanup_script" "$CFG" "$PLUGIN_DIR"
  say "Removed the plugin entry from $CFG"
fi

say ""
say "Kept: $CONFIG_DIR/memory/ and $CONFIG_DIR/backups/"
say "Delete them yourself if you do not want the logs, handoffs, and snapshots."
say ""
say "note: \"compaction.auto\" is still false in $CFG;"
say "set it to true if you want OpenCode's built-in compaction again."
