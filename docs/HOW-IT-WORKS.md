# How token-guard works

This is the detailed walkthrough: what runs, when it runs, and what it touches.

## Components

```
plugin/index.ts             OpenCode plugin (event listener + `handoff` tool)
bin/oc-auto-reinstall       detached helper: backup, reinstall, compact
bin/oc-safe-reinstall       manual helper: snapshot / reinstall / restore
opencode.example.json       config snippet
install.sh / uninstall.sh   install and removal
```

Runtime state lives in `~/.config/opencode/`:

```
memory/token-guard.log      activity log
memory/reinstall.log        helper log
memory/handoff-*.md         transcripts, one per event
memory/latest-handoff.md    newest transcript
memory/.lock-*              per-session action locks
memory/.reinstall-*         in-flight / completed markers
backups/                    DB, config, binary snapshots
```

## Event flow

The plugin subscribes to `ctx.event` and only reacts to:

| Event | Use |
| --- | --- |
| `session.step.ended` | token counts for the step, the main trigger |
| `session.compaction.started` | mark session as compacting |
| `session.compaction.ended` | clear the marker, reset cooldown |
| `session.compaction.failed` | clear the marker |

### Token accounting

```text
used = input + cache.read + cache.write + output
ratio = used / inputLimit
```

`inputLimit` is read from the model metadata: `limit.input`, otherwise
`limit.context - limit.output`, otherwise the `inputLimit` option (160000).
The value is cached per session for five minutes.

### Actions, in priority order

1. **Warning** at `warnAt` (default 75%). Log only. One per `warnCooldownMs`.
2. **Reinstall** at `reinstallAt` (default off). Writes a handoff, creates a
   marker, spawns `oc-auto-reinstall --session <id>` detached, then **skips
   compaction while the marker exists**.
3. **Handoff** at `handoffAt` (default 95%). Extra transcript snapshot.
4. **Compaction** at `compactAt` (default 85%). Writes a pre-compaction
   handoff, then calls `ctx.session.compact({ sessionID })`.

Locks are files created with `O_EXCL` and a TTL, so two runtimes in the same
server do not double-fire. `compaction.auto` should be `false` in
`opencode.json`; otherwise OpenCode's own compaction races this plugin.

## Handoff format

`memory/handoff-<timestamp>.md`:

```markdown
# OpenCode session handoff

- session: ses_...
- title: ...
- model: provider/model
- reason: automatic: before compaction
- created: 2026-01-01T00:00:00.000Z

Continue the work from this transcript in a fresh session.

## USER
...

## ASSISTANT
...
```

The last 60 messages are kept, capped at `handoffMaxChars` (16000) from the
tail. `latest-handoff.md` is always a copy of the newest file.

## oc-auto-reinstall (hot mode)

Started as a detached child so it survives the session that spawned it.

1. **Single instance:** `flock` on `memory/.reinstall.lock`.
2. **Idle wait:** polls `opencode api get /api/session/active` until no session
   reports `"running"`, sleeping 10 seconds between checks. Default deadline is
   600 seconds (`--wait`). On timeout it posts a compaction request and exits.
3. **DB snapshot:** `sqlite3 .backup` to `backups/opencode-<stamp>.db`, then
   `pragma integrity_check`; aborts if the result is not `ok`.
4. **Config + binary snapshot:** `backups/config-<stamp>.tar.gz` and
   `backups/opencode-bin-<stamp>`.
5. **Prune:** keeps 3 databases, 2 config archives, 1 binary.
6. **Installer:** downloads `https://opencode.ai/v2/install` (the plain
   `/install` URL is OpenCode 1) into a temp file.
7. **Install:** pins the currently running version first, falls back to latest,
   then to the local binary copy. In hot mode the binary is replaced while the
   service keeps running.
8. **Verify:** binary runs, major version is not downgraded from 2 to 1,
   database still passes `integrity_check`, session count did not drop;
   otherwise the previous binary / DB backup is restored.
9. **Compact:** posts to `/api/session/<id>/compact` so the same session
   continues with fresh tokens.
10. **Mark done:** writes `.reinstall-done-<session>` with a timestamp; the
    plugin will not reinstall that session again for 24 hours.

`--cold` does the literal version: stop service, `opencode uninstall --force`,
install, start service, reopen OpenCode, run `/resume`.

## Known behavior and limits

- **Compaction is suppressed while a reinstall is pending.** If the helper is
  stuck waiting for idle sessions, context can grow past the model limit before
  the 10-minute timeout fires the fallback compaction. Use `reinstallAt: 0`, or
  keep the wait short, if you regularly run many sessions at once.
- **Idle means every session.** `/api/session/active` reports all sessions; a
  background session keeps the helper waiting.
- **Ratio includes cache and output tokens**, so it can read higher than the
  visible input size.
- The plugin is per server; a lock file prevents duplicate actions but each
  runtime still evaluates the ratio.

## Disable

```sh
./uninstall.sh                    # removes plugin entry and scripts
```

Or set `reinstallAt: 0` to keep warnings and compaction only. Nothing in
`~/.local/share/opencode/opencode.db` is ever touched by removal.
