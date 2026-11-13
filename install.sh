#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  OPENCODE UNLIMITED TOKENS
#  install / uninstall
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/opencode-unlimited-tokens"
OLD_PLUGIN_DIR="$CONFIG_DIR/plugins/token-guard"
BIN_DIR="$HOME/.local/bin"
CFG="$CONFIG_DIR/opencode.json"

say()  { printf '\033[0;36m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
opencode-unlimited-tokens

  ./install.sh              install plugin + helpers
  ./install.sh --uninstall  remove plugin + helpers
  ./install.sh --help       this text
EOF
}

merge_config() {
  local mode="$1" merge_script
  merge_script="$(mktemp)"
  cat >"$merge_script" <<'NODE'
const fs = require("fs")
const [mode, cfgPath, pluginPath, oldPluginPath, scriptPath] = process.argv.slice(2)

let cfg = {}
if (fs.existsSync(cfgPath)) {
  const raw = fs.readFileSync(cfgPath, "utf8").trim()
  cfg = raw ? JSON.parse(raw) : {}
}

const pkg = (entry) => (typeof entry === "string" ? entry : entry && entry.package)

if (mode === "uninstall") {
  if (Array.isArray(cfg.plugins)) {
    cfg.plugins = cfg.plugins.filter((e) => pkg(e) !== pluginPath && pkg(e) !== oldPluginPath)
    if (cfg.plugins.length === 0) delete cfg.plugins
  }
  if (cfg.commands && typeof cfg.commands === "object") {
    const ours = (cmd, marker) => cmd && typeof cmd.template === "string" && cmd.template.includes(marker)
    if (ours(cfg.commands.handoff, "`handoff` tool")) delete cfg.commands.handoff
    if (ours(cfg.commands.resume, "latest-handoff.md")) delete cfg.commands.resume
    if (Object.keys(cfg.commands).length === 0) delete cfg.commands
  }
} else {
  cfg.compaction = { ...(cfg.compaction || {}), auto: false }
  cfg.plugins = Array.isArray(cfg.plugins) ? cfg.plugins : []
  // drop the pre-rebrand entry so the plugin never loads twice
  cfg.plugins = cfg.plugins.filter((e) => pkg(e) !== oldPluginPath)

  const options = {
    warnAt: 0.7,
    reinstallAt: 0.85,
    compactAt: 0.9,
    handoffAt: 0.95,
    reinstallScript: scriptPath,
  }
  const index = cfg.plugins.findIndex((e) => pkg(e) === pluginPath)
  if (index >= 0) {
    const entry = cfg.plugins[index]
    if (typeof entry === "string") cfg.plugins[index] = { package: pluginPath, options }
    else entry.options = { ...options, ...(entry.options || {}), reinstallScript: scriptPath }
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
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n")
NODE
  node "$merge_script" "$mode" "$CFG" "$PLUGIN_DIR" "$OLD_PLUGIN_DIR" "$BIN_DIR/oc-auto-reinstall"
  rm -f "$merge_script"
}

do_install() {
  command -v opencode >/dev/null 2>&1 || warn "opencode not in PATH"
  for tool in sqlite3 curl node; do
    command -v "$tool" >/dev/null 2>&1 || warn "$tool missing"
  done

  say "payload -> $PLUGIN_DIR"
  mkdir -p "$CONFIG_DIR" "$BIN_DIR"
  # migrate the pre-rebrand install instead of leaving a second copy behind
  if [ -d "$OLD_PLUGIN_DIR" ] && [ ! -d "$PLUGIN_DIR" ]; then
    mv "$OLD_PLUGIN_DIR" "$PLUGIN_DIR"
    say "migrated old plugin dir"
  fi
  mkdir -p "$PLUGIN_DIR"
  install -m 644 "$REPO_DIR/plugin/index.ts" "$PLUGIN_DIR/index.ts"

  say "helpers -> $BIN_DIR"
  install -m 755 "$REPO_DIR/bin/oc-auto-reinstall" "$BIN_DIR/oc-auto-reinstall"
  install -m 755 "$REPO_DIR/bin/oc-safe-reinstall" "$BIN_DIR/oc-safe-reinstall"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in PATH" ;;
  esac

  if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    say "config backed up"
  fi
  merge_config install
  say "config patched -> $CFG"

  printf '\n'
  say "armed. restart opencode / open a new session."
  say "log: $CONFIG_DIR/memory/unlimited-tokens.log"
  warn "set reinstallAt: 0 in $CFG for compaction only"
}

do_uninstall() {
  rm -rf "$PLUGIN_DIR" "$OLD_PLUGIN_DIR"
  say "plugin removed"
  for f in "$BIN_DIR/oc-auto-reinstall" "$BIN_DIR/oc-safe-reinstall"; do
    if [ -e "$f" ]; then
      rm -f "$f"
      say "removed $f"
    fi
  done
  if [ -f "$CFG" ] && command -v node >/dev/null 2>&1; then
    cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    merge_config uninstall
    say "config cleaned -> $CFG"
  fi
  say "kept: $CONFIG_DIR/memory/ and $CONFIG_DIR/backups/"
  warn "compaction.auto is still false; set it true for built-in compaction"
}

case "${1:-install}" in
  install|--install|"") do_install ;;
  uninstall|--uninstall|-u) do_uninstall ;;
  -h|--help|help) usage ;;
  *) die "unknown option: $1 (try --help)" ;;
esac
