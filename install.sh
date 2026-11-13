#!/usr/bin/env bash
# Install the token-guard plugin and helper scripts for the current user.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/token-guard"
BIN_DIR="$HOME/.local/bin"
CFG="$CONFIG_DIR/opencode.json"

say() { printf '%s\n' "$*"; }

if ! command -v opencode >/dev/null 2>&1; then
  say "warning: 'opencode' not found in PATH; install it before using the plugin"
fi
for tool in sqlite3 curl; do
  command -v "$tool" >/dev/null 2>&1 || say "warning: '$tool' not found; the reinstall helper needs it"
done

say "Installing plugin to $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR" "$BIN_DIR" "$CONFIG_DIR"
install -m 644 "$REPO_DIR/plugin/index.ts" "$PLUGIN_DIR/index.ts"

say "Installing helpers to $BIN_DIR"
install -m 755 "$REPO_DIR/bin/oc-auto-reinstall" "$BIN_DIR/oc-auto-reinstall"
install -m 755 "$REPO_DIR/bin/oc-safe-reinstall" "$BIN_DIR/oc-safe-reinstall"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "warning: $BIN_DIR is not in PATH; add it to use oc-auto-reinstall from the plugin" ;;
esac

if ! command -v node >/dev/null 2>&1; then
  say ""
  say "node not found: merge this into $CFG manually (replace /home/you and ~):"
  cat "$REPO_DIR/opencode.example.json"
  exit 0
fi

if [ -f "$CFG" ]; then
  backup="$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$backup"
  say "Config backup: $backup"
fi

merge_script="$(mktemp)"
trap 'rm -f "$merge_script"' EXIT
cat >"$merge_script" <<'NODE'
const fs = require("fs")
const [cfgPath, pluginPath, reinstallScript] = process.argv.slice(2)

let cfg = {}
if (fs.existsSync(cfgPath)) {
  const raw = fs.readFileSync(cfgPath, "utf8").trim()
  cfg = raw ? JSON.parse(raw) : {}
}

cfg.compaction = { ...(cfg.compaction || {}), auto: false }
cfg.plugins = Array.isArray(cfg.plugins) ? cfg.plugins : []

const options = {
  warnAt: 0.7,
  reinstallAt: 0.85,
  compactAt: 0.9,
  handoffAt: 0.95,
  reinstallScript,
}

const index = cfg.plugins.findIndex(
  (entry) => (typeof entry === "string" ? entry : entry && entry.package) === pluginPath,
)
if (index >= 0) {
  const entry = cfg.plugins[index]
  if (typeof entry === "string") {
    cfg.plugins[index] = { package: pluginPath, options }
  } else {
    entry.options = { ...(entry.options || {}), ...options }
  }
} else {
  cfg.plugins.push({ package: pluginPath, options })
}

cfg.commands = { ...(cfg.commands || {}) }
cfg.commands.handoff = cfg.commands.handoff || {
  description: "Save the current session to a memory file",
  template:
    "Call the `handoff` tool with a short note describing the current task. Then tell me the memory file path and that I can start a new session to continue.",
}
cfg.commands.resume = cfg.commands.resume || {
  description: "Continue from the latest handoff memory",
  template:
    "Read the file ~/.config/opencode/memory/latest-handoff.md and continue the work described there. First summarize what was in progress and what the next step is.",
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n")
NODE

node "$merge_script" "$CFG" "$PLUGIN_DIR" "$BIN_DIR/oc-auto-reinstall"

say ""
say "Done. Restart OpenCode (or open a new session) to load the plugin."
say "Activity log: $CONFIG_DIR/memory/token-guard.log"
say "To disable the automatic reinstall step, set \"reinstallAt\": 0 in $CFG"
