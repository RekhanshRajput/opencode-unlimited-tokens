#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  OPENCODE UNLIMITED TOKENS
#  zero-touch installer
#    ./install.sh                install everything, auto-install deps
#    ./install.sh --no-restart   do not touch the running service
#    ./install.sh --no-opencode  do not install opencode automatically
#    ./install.sh --no-sqlite    do not install sqlite3 automatically
#    ./install.sh --uninstall
# ─────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/opencode-unlimited-tokens"
OLD_PLUGIN_DIR="$CONFIG_DIR/plugins/token-guard"
BIN_DIR="$HOME/.local/bin"
CFG="$CONFIG_DIR/opencode.json"
RESTART=1
AUTO_OPENCODE=1
AUTO_SQLITE=1
MODE="install"

for arg in "$@"; do
  case "$arg" in
    --uninstall|-u) MODE="uninstall" ;;
    --no-restart) RESTART=0 ;;
    --restart) RESTART=1 ;;
    --no-opencode) AUTO_OPENCODE=0 ;;
    --no-sqlite) AUTO_SQLITE=0 ;;
    --help|-h) MODE="help" ;;
    *) printf '\033[0;31m[x]\033[0m unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

say()  { printf '\033[0;36m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
opencode-unlimited-tokens

  ./install.sh                install everything (auto-installs opencode + sqlite3)
  ./install.sh --no-restart   do not touch the running service
  ./install.sh --no-opencode  do not install opencode automatically
  ./install.sh --no-sqlite    do not install sqlite3 automatically
  ./install.sh --uninstall    remove plugin, helpers, commands
EOF
}

ensure_path_dir() {
  local dir="$1" rel marker line rc
  dir="${dir%/}"
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  export PATH="$dir:$PATH"
  rel="${dir/#$HOME/\$HOME}"
  marker="# opencode-unlimited-tokens: $rel"
  line="export PATH=\"$rel:\$PATH\""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -qsF "$marker" "$rc" && continue
    printf '\n%s\n%s\n' "$marker" "$line" >>"$rc"
    say "PATH updated in $rc"
  done
}

ensure_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    say "opencode found: $(opencode --version 2>/dev/null | head -1)"
    return 0
  fi
  local candidate
  for candidate in "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode /opt/homebrew/bin/opencode; do
    if [ -x "$candidate" ]; then
      say "found opencode at $candidate"
      ensure_path_dir "$(dirname "$candidate")"
      return 0
    fi
  done
  if [ "$AUTO_OPENCODE" -ne 1 ]; then
    warn "opencode not installed; run: curl -fsSL https://opencode.ai/v2/install | bash"
    return 1
  fi
  say "opencode missing; installing OpenCode 2"
  local inst src
  inst="$(mktemp)"
  src="${UT_OPENCODE_INSTALLER:-https://opencode.ai/v2/install}"
  if [ -f "$src" ]; then
    cp "$src" "$inst"
  elif ! curl -fsSL --max-time 180 "$src" -o "$inst"; then
    rm -f "$inst"
    warn "could not download the opencode installer"
    return 1
  fi
  if ! bash "$inst" --no-modify-path >/dev/null 2>&1; then
    bash "$inst" >/dev/null 2>&1 || true
  fi
  rm -f "$inst"
  ensure_path_dir "$HOME/.opencode/bin"
  if command -v opencode >/dev/null 2>&1; then
    say "opencode installed: $(opencode --version 2>/dev/null | head -1)"
    return 0
  fi
  warn "automatic install failed; run: curl -fsSL https://opencode.ai/v2/install | bash"
  return 1
}

ensure_sqlite() {
  if command -v sqlite3 >/dev/null 2>&1; then
    say "sqlite3 found"
    return 0
  fi
  if [ "$AUTO_SQLITE" -eq 1 ] && command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    say "sqlite3 missing; installing via apt"
    sudo -n apt-get update -qq >/dev/null 2>&1 || true
    if sudo -n apt-get install -y -qq sqlite3 >/dev/null 2>&1; then
      say "sqlite3 installed"
      return 0
    fi
  fi
  warn "sqlite3 missing; raw-copy DB backups will be used"
  return 1
}

restart_opencode() {
  command -v opencode >/dev/null 2>&1 || return 0
  if ! opencode service status >/dev/null 2>&1; then
    say "no background service running; plugin loads with the next session"
    return 0
  fi
  say "restarting opencode service to load the plugin"
  opencode service restart >/dev/null 2>&1 || {
    opencode service stop >/dev/null 2>&1 || true
    sleep 1
    opencode service start >/dev/null 2>&1 || true
  }
}

merge_config() {
  local mode="$1"
  if command -v python3 >/dev/null 2>&1; then
  python3 - "$mode" "$CFG" "$PLUGIN_DIR" "$OLD_PLUGIN_DIR" "$BIN_DIR/oc-auto-reinstall" <<'PY'
import json, os, sys

mode, cfg_path, plugin_path, old_path, script_path = sys.argv[1:6]

cfg = {}
if os.path.exists(cfg_path):
    raw = open(cfg_path, encoding="utf-8").read().strip()
    cfg = json.loads(raw) if raw else {}


def pkg(entry):
    if isinstance(entry, str):
        return entry
    return (entry or {}).get("package")


if mode == "uninstall":
    if isinstance(cfg.get("plugins"), list):
        cfg["plugins"] = [e for e in cfg["plugins"] if pkg(e) not in (plugin_path, old_path)]
        if not cfg["plugins"]:
            del cfg["plugins"]
    commands = cfg.get("commands")
    if isinstance(commands, dict):
        def ours(name, marker):
            cmd = commands.get(name)
            return isinstance(cmd, dict) and marker in str(cmd.get("template", ""))

        if ours("handoff", "`handoff` tool"):
            del commands["handoff"]
        if ours("resume", "latest-handoff.md"):
            del commands["resume"]
        if ours("tokens", "`token_status` tool"):
            del commands["tokens"]
        if ours("compact-now", "`compact_now` tool"):
            del commands["compact-now"]
        if not commands:
            del cfg["commands"]
else:
    cfg["compaction"] = {**(cfg.get("compaction") or {}), "auto": False}
    plugins = cfg.get("plugins")
    plugins = plugins if isinstance(plugins, list) else []
    plugins = [e for e in plugins if pkg(e) != old_path]

    options = {
        "warnAt": 0.7,
        "reinstallAt": 0.85,
        "compactAt": 0.9,
        "handoffAt": 0.95,
        "reinstallScript": script_path,
    }
    index = next((i for i, e in enumerate(plugins) if pkg(e) == plugin_path), None)
    if index is None:
        plugins.append({"package": plugin_path, "options": options})
    else:
        entry = plugins[index]
        if isinstance(entry, str):
            plugins[index] = {"package": plugin_path, "options": options}
        else:
            entry["options"] = {**options, **(entry.get("options") or {}), "reinstallScript": script_path}
    cfg["plugins"] = plugins

    commands = cfg.get("commands") if isinstance(cfg.get("commands"), dict) else {}
    commands.setdefault(
        "handoff",
        {
            "description": "Save the current session to a memory file",
            "template": "Call the `handoff` tool with a short note describing the current task. Then tell me the memory file path and that I can start a new session to continue.",
        },
    )
    commands.setdefault(
        "resume",
        {
            "description": "Continue from the latest handoff memory",
            "template": "Read the file ~/.config/opencode/memory/latest-handoff.md and continue the work described there. First summarize what was in progress and what the next step is.",
        },
    )
    commands.setdefault(
        "tokens",
        {
            "description": "Show context usage and remaining budget",
            "template": "Call the `token_status` tool and show me the exact output. If usage is above the compact threshold, ask before compacting.",
        },
    )
    commands.setdefault(
        "compact-now",
        {
            "description": "Compact this session immediately",
            "template": "Call the `compact_now` tool and confirm when the compaction was requested.",
        },
    )
    cfg["commands"] = commands

with open(cfg_path, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
    handle.write("\n")
PY
  elif command -v node >/dev/null 2>&1; then
  node - "$mode" "$CFG" "$PLUGIN_DIR" "$OLD_PLUGIN_DIR" "$BIN_DIR/oc-auto-reinstall" <<'JS'
const fs = require("fs")
const [mode, cfgPath, pluginPath, oldPath, scriptPath] = process.argv.slice(2)
const pkg = (e) => (typeof e === "string" ? e : e && e.package)
const cfg = fs.existsSync(cfgPath)
  ? (() => {
      const raw = fs.readFileSync(cfgPath, "utf8").trim()
      return raw ? JSON.parse(raw) : {}
    })()
  : {}

const commands = cfg.commands && typeof cfg.commands === "object" ? cfg.commands : {}

if (mode === "uninstall") {
  if (Array.isArray(cfg.plugins)) {
    cfg.plugins = cfg.plugins.filter((e) => pkg(e) !== pluginPath && pkg(e) !== oldPath)
    if (!cfg.plugins.length) delete cfg.plugins
  }
  const ours = (name, marker) => {
    const cmd = commands[name]
    return cmd && typeof cmd.template === "string" && cmd.template.includes(marker)
  }
  if (ours("handoff", "`handoff` tool")) delete commands.handoff
  if (ours("resume", "latest-handoff.md")) delete commands.resume
  if (ours("tokens", "`token_status` tool")) delete commands.tokens
  if (ours("compact-now", "`compact_now` tool")) delete commands["compact-now"]
  if (Object.keys(commands).length) cfg.commands = commands
  else delete cfg.commands
} else {
  cfg.compaction = { ...(cfg.compaction || {}), auto: false }
  const plugins = (Array.isArray(cfg.plugins) ? cfg.plugins : []).filter((e) => pkg(e) !== oldPath)
  const options = {
    warnAt: 0.7,
    reinstallAt: 0.85,
    compactAt: 0.9,
    handoffAt: 0.95,
    reinstallScript: scriptPath,
  }
  const index = plugins.findIndex((e) => pkg(e) === pluginPath)
  if (index === -1) plugins.push({ package: pluginPath, options })
  else if (typeof plugins[index] === "string") plugins[index] = { package: pluginPath, options }
  else plugins[index].options = { ...options, ...(plugins[index].options || {}), reinstallScript: scriptPath }
  cfg.plugins = plugins

  commands.handoff = commands.handoff || {
    description: "Save the current session to a memory file",
    template:
      "Call the `handoff` tool with a short note describing the current task. Then tell me the memory file path and that I can start a new session to continue.",
  }
  commands.resume = commands.resume || {
    description: "Continue from the latest handoff memory",
    template:
      "Read the file ~/.config/opencode/memory/latest-handoff.md and continue the work described there. First summarize what was in progress and what the next step is.",
  }
  commands.tokens = commands.tokens || {
    description: "Show context usage and remaining budget",
    template:
      "Call the `token_status` tool and show me the exact output. If usage is above the compact threshold, ask before compacting.",
  }
  commands["compact-now"] = commands["compact-now"] || {
    description: "Compact this session immediately",
    template: "Call the `compact_now` tool and confirm when the compaction was requested.",
  }
  cfg.commands = commands
}

fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n")
JS
  else
    warn "node/python3 not found; patch $CFG by hand"
    return 1
  fi
}

do_install() {
  command -v curl >/dev/null 2>&1 || warn "curl missing (needed by the reinstall helper)"
  ensure_opencode || true
  ensure_sqlite || true

  say "payload -> $PLUGIN_DIR"
  mkdir -p "$CONFIG_DIR" "$BIN_DIR"
  if [ -d "$OLD_PLUGIN_DIR" ] && [ ! -d "$PLUGIN_DIR" ]; then
    mv "$OLD_PLUGIN_DIR" "$PLUGIN_DIR"
    say "migrated old plugin dir"
  fi
  mkdir -p "$PLUGIN_DIR"
  install -m 644 "$REPO_DIR/plugin/index.ts" "$PLUGIN_DIR/index.ts"

  say "helpers -> $BIN_DIR"
  install -m 755 "$REPO_DIR/bin/oc-auto-reinstall" "$BIN_DIR/oc-auto-reinstall"
  install -m 755 "$REPO_DIR/bin/oc-safe-reinstall" "$BIN_DIR/oc-safe-reinstall"
  ensure_path_dir "$BIN_DIR"

  if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    say "config backed up"
  fi
  merge_config install || true
  say "config patched -> $CFG"

  if [ "$RESTART" -eq 1 ]; then
    restart_opencode
  else
    say "skipped service restart (--no-restart)"
  fi

  printf '\n'
  say "armed. log: $CONFIG_DIR/memory/unlimited-tokens.log"
  say "commands: /tokens  /compact-now  /handoff  /resume"
  warn "reinstallAt defaults to 0.85; set it to 0 for compaction-only (no binary swap)"
  status_summary
}

status_summary() {
  local oc sq
  oc="$(command -v opencode >/dev/null 2>&1 && opencode --version 2>/dev/null | head -1 || echo missing)"
  if command -v sqlite3 >/dev/null 2>&1; then
    sq="$(sqlite3 --version 2>/dev/null | cut -d' ' -f1)"
  else
    sq="missing (raw-copy fallback)"
  fi
  printf '\n'
  say "status"
  printf '    opencode : %s\n' "$oc"
  printf '    sqlite3  : %s\n' "$sq"
  printf '    plugin   : %s\n' "$([ -f "$PLUGIN_DIR/index.ts" ] && echo "$PLUGIN_DIR/index.ts" || echo 'MISSING')"
  printf '    config   : %s\n' "$CFG"
}

do_uninstall() {
  rm -rf "$PLUGIN_DIR" "$OLD_PLUGIN_DIR"
  say "plugin removed"
  local f
  for f in "$BIN_DIR/oc-auto-reinstall" "$BIN_DIR/oc-safe-reinstall"; do
    if [ -e "$f" ]; then
      rm -f "$f"
      say "removed $f"
    fi
  done
  if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
    merge_config uninstall || true
    say "config cleaned -> $CFG"
  fi
  say "kept: $CONFIG_DIR/memory/ and $CONFIG_DIR/backups/"
  warn "compaction.auto is still false; set it true for built-in compaction"
  [ "$RESTART" -eq 1 ] && restart_opencode
}

case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  help) usage ;;
esac
