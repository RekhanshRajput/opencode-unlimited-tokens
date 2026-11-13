# token-guard

An [OpenCode](https://opencode.ai) plugin that watches model context usage and
keeps a session alive when the token budget fills up.

After every step it checks how much of the model's input budget is used and
reacts automatically:

| Usage | Action |
| --- | --- |
| 70% | warning in the activity log |
| 85% | saves a handoff transcript + schedules a hot binary reinstall (optional) |
| 90% | compacts the session (fallback, and the main recovery path) |
| 95% | extra handoff snapshot |

Sessions, history, config, and the SQLite database are **never deleted**. The
running session is never closed in the default hot mode.

## Requirements

- OpenCode 2.x
- `bash`, `curl`, `sqlite3`
- `node` (only used by the installer to merge JSON config)
- `flock` (optional, prevents two reinstalls at once)

## Install

```sh
git clone <your-repo-url> token-guard
cd token-guard
chmod +x install.sh
./install.sh
```

The installer:

1. Copies the plugin to `~/.config/opencode/plugins/token-guard/`.
2. Copies `oc-auto-reinstall` and `oc-safe-reinstall` to `~/.local/bin/`.
3. Merges the plugin entry and the `/handoff` + `/resume` commands into
   `~/.config/opencode/opencode.json` (a timestamped `.bak` is written first).
4. Sets `compaction.auto` to `false`, so OpenCode and this plugin do not both
   try to compact the same session.

Restart OpenCode (or open a new session) to load the plugin.

## Configuration

`~/.config/opencode/opencode.json`:

```json
{
  "compaction": { "auto": false },
  "plugins": [
    {
      "package": "/home/you/.config/opencode/plugins/token-guard",
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

Use an absolute `package` path. The installer fills in your real home directory.

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `warnAt` | `0.75` | log a warning at this ratio |
| `compactAt` | `0.85` | request session compaction at this ratio |
| `handoffAt` | `0.95` | write an extra handoff snapshot |
| `inputLimit` | `160000` | fallback input budget when the model does not report one |
| `reinstallAt` | `0` (off) | schedule `oc-auto-reinstall` at this ratio |
| `reinstallScript` | `~/.local/bin/oc-auto-reinstall` | helper to run |
| `cooldownMs` | `120000` | minimum gap between compact/handoff actions |
| `warnCooldownMs` | `300000` | minimum gap between warnings |
| `handoffMaxChars` | `16000` | transcript tail kept in a handoff file |
| `reinstallCooldownMs` | `86400000` | do not reinstall the same session twice in 24h |
| `verbose` | `false` | log usage even below `warnAt` |

The input budget comes from the model metadata (`limit.input`, or
`limit.context - limit.output`). If nothing is reported, `inputLimit` is used.

Set `reinstallAt` to `0` if you only want warnings and compaction. The
reinstall step is optional and off by default in the plugin itself.

## Commands

- `/handoff` — save the current transcript to
  `~/.config/opencode/memory/latest-handoff.md` right now.
- `/resume` — read `latest-handoff.md` and continue the work in a new session.

The `handoff` tool is also registered for the model, so it can save state
before a long operation on its own.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/opencode/plugins/token-guard/index.ts` | the plugin |
| `~/.config/opencode/opencode.json` | enable + thresholds |
| `~/.local/bin/oc-auto-reinstall` | hot/cold reinstall helper |
| `~/.local/bin/oc-safe-reinstall` | backup / restore helper |
| `~/.config/opencode/memory/token-guard.log` | activity log |
| `~/.config/opencode/memory/reinstall.log` | helper log |
| `~/.config/opencode/memory/latest-handoff.md` | newest handoff |
| `~/.config/opencode/backups/` | DB, config, and binary snapshots |

Backups are pruned automatically (3 databases, 2 config archives, 1 binary).

## How it works

The plugin subscribes to OpenCode events:

- `session.step.ended` gives token counts per step.
- `session.compaction.started` / `ended` / `failed` track compaction state.

Used tokens are computed as
`input + cache.read + cache.write + output`, divided by the model input budget.
A small file lock per session (`~/.config/opencode/memory/.lock-*`) makes sure
compaction and handoff fire only once even if the plugin is loaded by more than
one runtime in the same server.

`oc-auto-reinstall` runs detached and:

1. Waits for the session to become idle (default 10 minutes, `--wait` to change).
2. Backs up and integrity-checks the SQLite database.
3. Backs up config and the current binary.
4. Downloads the OpenCode 2 installer.
5. Replaces the binary on disk while the service keeps running; refuses to
   leave an OpenCode 1 binary behind.
6. Verifies DB integrity and session count, restores the backup on mismatch.
7. Requests compaction of the same session so it continues with fresh tokens.

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) for the full walkthrough.

## Troubleshooting

**Compaction never runs and the context keeps growing.**

Check `~/.config/opencode/memory/token-guard.log` for
`reinstall pending ... skipping compaction`. While a scheduled reinstall is
pending, the plugin deliberately skips compaction. The helper waits up to 10
minutes for **all** sessions to be idle; on timeout it compacts instead. In a
busy instance that means up to 10 minutes at 100%+ context.

Options:

- Set `reinstallAt` to `0` (compaction only, no waiting).
- Lower the wait: `oc-auto-reinstall --session <id> --wait 120`.
- Do not run many sessions at once when you are near the limit.

**`sqlite3: command not found`**

Install sqlite3; the helper needs it for `.backup` and `pragma integrity_check`.

**Plugin is not loaded.**

The `package` path must be absolute and the directory must contain `index.ts`.
Check the log file — a successful load writes a `setup start (...)` line.

## Manual helpers

```sh
oc-auto-reinstall                      # hot reinstall, session stays open
oc-auto-reinstall --dry-run            # backups + installer download only
oc-auto-reinstall --session <id>       # wait for idle, then reinstall + compaction
oc-auto-reinstall --session <id> --wait 120
oc-auto-reinstall --cold               # stop service, uninstall, reinstall, restart

oc-safe-reinstall backup               # snapshot the sessions database
oc-safe-reinstall                      # snapshot + reinstall binary (asks first)
oc-safe-reinstall restore FILE         # restore a snapshot (stops the service)
```

`--cold` is the only mode that closes the running session; reopen OpenCode and
run `/resume` afterwards.

## Uninstall

```sh
./uninstall.sh
```

Removes the plugin and helpers, and the plugin entry from `opencode.json`.
Handoffs, logs, and backups are left in place; delete
`~/.config/opencode/memory/` and `~/.config/opencode/backups/` yourself if you
do not want them. `compaction.auto` is left as `false`, so set it back to
`true` if you want OpenCode's built-in compaction again.

## Safety notes

- Automatic reinstall replaces the OpenCode binary on disk. It is off by
  default (`reinstallAt: 0`); set it only if you want that behavior.
- The helper takes a database backup and checks integrity before touching the
  binary, and restores the backup if the session count drops.
- Marker and lock files live in `~/.config/opencode/memory/` and are safe to
  delete while OpenCode is stopped.

## License

MIT — see [LICENSE](LICENSE).
