<div align="center">

```
 ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗ ██████╗ ██████╗ ███████╗
██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗██╔════╝
██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║   ██║██║  ██║█████╗
██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║   ██║██║  ██║██╔══╝
╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗╚██████╔╝██████╔╝███████╗
 ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝

        U N L I M I T E D   T O K E N S
```

**`> context full? never heard of her.`**

![platform](https://img.shields.io/badge/platform-linux%20%7C%20macos-black?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-00ff88?style=flat-square)
![setup](https://img.shields.io/badge/setup-one%20command-ff0044?style=flat-square)
![tokens](https://img.shields.io/badge/tokens-unlimited-9d00ff?style=flat-square)

OpenCode plugin that watches the context budget and **auto-dumps a handoff +
compacts the session** before the model chokes on its own history.
No closed session, no lost work, no manual `/compact` spam.

</div>

---

```txt
sitrep
  plugin      context watchdog, fires on session.step.ended
  trigger     70% warn | 85% handoff + reinstall hook | 90% compact | 95% snapshot
  commands    /tokens  /compact-now  /handoff  /resume
  install     one command. deps auto, config patched, PATH fixed, service restarted.
  damage      none. sessions, DB, config, history stay on disk
```

## [ 00 ] QUICK SETUP — copy, paste, done

```bash
# 1. INSTALL  (also installs opencode + sqlite3 if they are missing)
curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh | bash

# 2. RELOAD SHELL  (so PATH picks up opencode + helpers)
source ~/.bashrc

# 3. VERIFY  (read-only, changes nothing)
curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh | bash -s -- --check

# 4. START OPENCODE, then type /tokens inside a session
opencode
```

Step 1 is the only real step. Steps 2-4 just prove it works:

```txt
[ok] opencode  opencode v2.3.0
[ok] plugin    ~/.config/opencode/plugins/opencode-unlimited-tokens/index.ts
[ok] config    ~/.config/opencode/opencode.json
[ok] commands  /tokens /compact-now /handoff /resume
[ok] helpers   ~/.local/bin
[ok] sqlite3   3.46.1
```

`/tokens` inside OpenCode prints `used / budget / % / thresholds`.

## [ 01 ] INSTALL — one command, zero edits

```bash
curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh | bash
```

Command map (copy the exact line you need):

| action | command |
| --- | --- |
| install / setup | `curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh \| bash` |
| verify setup | `curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh \| bash -s -- --check` |
| install without service restart | `curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh \| bash -s -- --no-restart` |
| uninstall | `curl -fsSL https://raw.githubusercontent.com/RekhanshRajput/opencode-unlimited-tokens/main/bootstrap.sh \| bash -s -- --uninstall` |
| after install (new shell) | `source ~/.bashrc` |

Install does everything:

1. pulls the latest repo tarball (no `git` needed),
2. **installs OpenCode 2 first if it is missing** (or just fixes PATH if it is already on disk),
3. **installs `sqlite3` via apt when passwordless sudo is available**, else falls back to raw-copy DB backups,
4. installs the plugin + both helpers,
5. backs up and patches `~/.config/opencode/opencode.json` (thresholds + all commands),
6. adds `~/.local/bin` and `~/.opencode/bin` to your shell rc when missing,
7. restarts the OpenCode background service so the plugin is live immediately,
8. prints a status block (`opencode`, `sqlite3`, plugin, config).

`--check` is read-only and prints `[ok] / [!!] / [--]` for opencode, plugin,
config, commands, helpers, sqlite3, runtime, and service. Exit code is `1` if
anything critical is missing.

Skip any install step:

```bash
... | bash -s -- --no-restart    # keep current service
... | bash -s -- --no-opencode   # never auto-install opencode
... | bash -s -- --no-sqlite     # never touch apt
```

Manual clone (same result):

```bash
git clone https://github.com/RekhanshRajput/opencode-unlimited-tokens.git
cd opencode-unlimited-tokens
./install.sh
./install.sh --check
```

Hard requirements: `curl` + `tar` only. Everything else is auto-detected,
auto-installed, or gracefully degraded.

## [ 02 ] LOADOUT

The installer writes this for you:

```json
{
  "compaction": { "auto": false },
  "plugins": [
    {
      "package": "/home/you/.config/opencode/plugins/opencode-unlimited-tokens",
      "options": {
        "warnAt": 0.7,
        "reinstallAt": 0.85,
        "compactAt": 0.9,
        "handoffAt": 0.95,
        "reinstallScript": "/home/you/.local/bin/oc-auto-reinstall"
      }
    }
  ]
}
```

`compaction.auto: false` is **required** — otherwise OpenCode's built-in
compaction fights the plugin for the same session.

| option | default | job |
| --- | --- | --- |
| `warnAt` | `0.75` | log a warning |
| `compactAt` | `0.85` | fire `session.compact()` |
| `handoffAt` | `0.95` | extra transcript snapshot |
| `reinstallAt` | `0` (off) | spawn the reinstall helper |
| `inputLimit` | `160000` | fallback budget if the model reports none |
| `cooldownMs` | `120000` | min gap between compact/handoff |
| `warnCooldownMs` | `300000` | min gap between warnings |
| `handoffMaxChars` | `16000` | transcript tail kept |
| `reinstallCooldownMs` | `86400000` | 24h reinstall lock per session |

Budget source: `limit.input`, else `limit.context - limit.output`, else
`inputLimit`. Cached per session for 5 minutes.

## [ 03 ] TRIGGERS

```txt
70%  ── warning                       log only
85%  ── handoff + reinstall hook      optional, reinstallAt
90%  ── COMPACT                       the real save
95%  ── snapshot                      extra handoff
```

## [ 04 ] COMMANDS

| command | what happens |
| --- | --- |
| `/tokens` | prints used / budget / % / thresholds |
| `/compact-now` | handoff + compaction, right now |
| `/handoff` | write `memory/latest-handoff.md` |
| `/resume` | new session reads that file and continues |

Tools registered for the model: `token_status`, `compact_now`, `handoff`.

Manual helpers:

```bash
oc-auto-reinstall                       # hot swap binary + compact, session stays open
oc-auto-reinstall --dry-run             # backup + download only
oc-auto-reinstall --session <id>        # wait for idle, then swap + compact
oc-auto-reinstall --session <id> --wait 120
oc-auto-reinstall --cold                # stop service, uninstall, reinstall, restart

oc-safe-reinstall backup                # DB snapshot
oc-safe-reinstall                       # snapshot + binary reinstall
oc-safe-reinstall restore FILE          # roll back (stops service)
```

## [ 05 ] MECHANICS

```txt
used  = input + cache.read + cache.write + output
ratio = used / inputLimit
```

Events consumed:

| event | use |
| --- | --- |
| `session.step.ended` | token counters, main trigger |
| `session.compaction.started` | mark busy |
| `session.compaction.ended` | clear + reset cooldown |
| `session.compaction.failed` | clear busy |

Per-session `O_EXCL` lock files (`.lock-*`) stop double-fire when the plugin is
loaded by more than one runtime. Handoffs keep the last 60 messages, tail-capped
at `handoffMaxChars`.

Hot reinstall (`oc-auto-reinstall`) sequence:

```txt
flock -> wait idle (600s) -> DB .backup + integrity_check
      -> config tar + binary copy -> prune old snapshots
      -> download installer -> swap binary -> version guard
      -> verify DB + session count -> compact session -> done marker
```

Rollback path: backup binary, backup DB, restore on missing binary, failed
version check, corrupt DB, or dropped session count.

## [ 06 ] FILE MAP

| path | what lives there |
| --- | --- |
| `bootstrap.sh` | one-liner remote installer (tarball, no git) |
| `install.sh` | install / uninstall, config merge, PATH, service restart |
| `plugin/index.ts` | event loop, ratio math, locks, handoff writer, tools |
| `bin/oc-auto-reinstall` | detached hot/cold reinstall + backup + compaction |
| `bin/oc-safe-reinstall` | manual snapshot / restore / reinstall |
| `README.md` | this file |
| `.gitignore` | keeps logs, DB, handoffs, markers out of git |

Runtime state (`~/.config/opencode/`):

```txt
memory/unlimited-tokens.log     activity
memory/reinstall.log            helper output
memory/handoff-*.md             transcripts
memory/latest-handoff.md        newest transcript
memory/.lock-*                  per-session locks
memory/.reinstall-*             in-flight / done markers
backups/                        DB + config + binary snapshots
```

## [ 07 ] KNOWN LIMITS

- **Reinstall pending blocks compaction.** While the 85% helper hunts for an
  idle window (up to 10 min), the plugin skips compaction. On a busy instance
  that can hit the hard model limit first. Fix: `"reinstallAt": 0`, or
  `--wait 120`.
- **Idle means every session.** `/api/session/active` is global; one background
  session keeps the helper waiting.
- **Ratio includes cache + output tokens**, so it can read hotter than the raw
  input size.
- **Not a quota bypass.** This frees *context* by compacting. It does not touch
  provider billing, rate limits, or account quotas.

## [ 08 ] UNINSTALL

```bash
./install.sh --uninstall
```

Removes plugin, helpers, the plugin entry, and the four commands. Logs,
handoffs, and backups stay in `~/.config/opencode/memory/` and
`~/.config/opencode/backups/`. `compaction.auto` is left `false`; set it `true`
for built-in compaction again.

## [ 09 ] LICENSE

MIT. See [LICENSE](LICENSE). Use it on your own machine, at your own risk —
the reinstall path replaces the OpenCode binary on disk.
