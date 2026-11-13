import { spawn } from "node:child_process"
import { appendFile, chmod, mkdir, open, readFile, stat, unlink, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

const MEMORY_DIR = join(homedir(), ".config", "opencode", "memory")
const LOG_FILE = join(MEMORY_DIR, "unlimited-tokens.log")

const DEFAULTS = {
  warnAt: 0.75,
  compactAt: 0.85,
  handoffAt: 0.95,
  inputLimit: 160_000,
  cooldownMs: 120_000,
  warnCooldownMs: 300_000,
  handoffMaxChars: 16_000,
  verbose: false,
  // Automatic uninstall + reinstall. Disabled when 0 or unset.
  reinstallAt: 0,
  reinstallScript: join(homedir(), ".local", "bin", "oc-auto-reinstall"),
  // After a reinstall, do not reinstall the same session again for a while.
  reinstallCooldownMs: 86_400_000,
  // How long one scheduled reinstall blocks new attempts (helper waits 10 min).
  reinstallLockTtlMs: 900_000,
}

const now = () => Date.now()

async function log(message: string) {
  try {
    await mkdir(MEMORY_DIR, { recursive: true, mode: 0o700 })
    await appendFile(LOG_FILE, `${new Date().toISOString()} ${message}\n`)
    await chmod(LOG_FILE, 0o600)
  } catch {
    // logging must never break OpenCode
  }
}

// The plugin can be loaded by more than one runtime in the same server.
// A tiny file lock keeps compaction / handoff from firing twice.
async function tryLock(key: string, ttlMs: number): Promise<boolean> {
  const file = join(MEMORY_DIR, `.lock-${key}`)
  try {
    const handle = await open(file, "wx")
    await handle.writeFile(String(now()))
    await handle.close()
    return true
  } catch {
    try {
      const stamp = Number(await readFile(file, "utf8"))
      if (!Number.isFinite(stamp) || now() - stamp > ttlMs) {
        await writeFile(file, String(now()))
        return true
      }
    } catch {
      // ignore and fall through
    }
    return false
  }
}

const MARKER_TTL_MS = 2 * 60 * 60 * 1000

async function markerExists(sessionID: string): Promise<boolean> {
  const file = join(MEMORY_DIR, `.reinstall-${sessionID}.json`)
  try {
    const info = await stat(file)
    if (now() - info.mtimeMs > MARKER_TTL_MS) {
      // The helper probably died; do not block future attempts forever.
      await unlink(file).catch(() => undefined)
      return false
    }
    return true
  } catch {
    return false
  }
}

async function recentlyReinstalled(sessionID: string, cooldownMs: number): Promise<boolean> {
  try {
    const stamp = Number(await readFile(join(MEMORY_DIR, `.reinstall-done-${sessionID}`), "utf8"))
    return Number.isFinite(stamp) && now() - stamp < cooldownMs
  } catch {
    return false
  }
}

// Start the reinstall helper fully detached so it survives this session and can
// wait for OpenCode to become idle before replacing the binary.
function spawnReinstall(script: string, sessionID: string): number {
  const child = spawn("bash", [script, "--session", sessionID], {
    detached: true,
    stdio: "ignore",
    env: process.env,
  })
  child.on("error", (error) => {
    void log(`reinstall spawn failed: ${String(error)}`)
  })
  child.unref()
  return child.pid ?? -1
}

function messageText(message: any): string {
  if (typeof message?.text === "string" && message.text) return message.text
  const content = message?.content
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  const parts: string[] = []
  for (const part of content) {
    if (typeof part === "string") {
      parts.push(part)
      continue
    }
    if (!part || typeof part !== "object") continue
    if (part.type === "text" && typeof part.text === "string") {
      parts.push(part.text)
    } else if (part.type === "tool") {
      const status = part.state?.status ? ` (${part.state.status})` : ""
      parts.push(`[tool: ${part.name ?? "unknown"}${status}]`)
    }
  }
  return parts.join("\n")
}

function asArray(value: any): any[] {
  if (Array.isArray(value)) return value
  for (const key of ["models", "data", "items"]) {
    if (value && Array.isArray(value[key])) return value[key]
  }
  return []
}

const limitCache = new Map<string, { limit: number; at: number }>()

async function inputLimit(ctx: any, sessionID: string): Promise<number> {
  const cached = limitCache.get(sessionID)
  if (cached && now() - cached.at < 300_000) return cached.limit

  try {
    const session = await ctx.session.get({ sessionID })
    let ref = session?.model
    if (!ref) {
      try {
        const fallback = await ctx.model.default()
        if (fallback) ref = { providerID: fallback.providerID, id: fallback.modelID ?? fallback.id }
      } catch {
        // ignore
      }
    }
    if (ref) {
      const models = asArray(await ctx.model.list())
      const model = models.find(
        (item: any) => item.providerID === ref.providerID && (item.id === ref.id || item.modelID === ref.id),
      )
      const limit = model?.limit
      const value =
        limit?.input > 0
          ? limit.input
          : limit?.context > 0
            ? Math.max(1, limit.context - (limit.output ?? 0))
            : DEFAULTS.inputLimit
      limitCache.set(sessionID, { limit: value, at: now() })
      return value
    }
  } catch (error) {
    await log(`limit lookup failed for ${sessionID}: ${String(error)}`)
  }
  return DEFAULTS.inputLimit
}

async function writeHandoff(ctx: any, sessionID: string, reason: string): Promise<string> {
  const session = await ctx.session.get({ sessionID }).catch(() => undefined)
  const messages = await ctx.session.context({ sessionID }).catch(() => [])
  const blocks: string[] = []

  for (const message of messages.slice(-60)) {
    const text = messageText(message).trim()
    if (!text) continue
    const role =
      message.type === "user"
        ? "USER"
        : message.type === "assistant"
          ? "ASSISTANT"
          : String(message.type ?? "MESSAGE").toUpperCase()
    blocks.push(`## ${role}\n${text}`)
  }

  let body = blocks.join("\n\n")
  if (body.length > DEFAULTS.handoffMaxChars) {
    body = "…(older context trimmed)…\n\n" + body.slice(-DEFAULTS.handoffMaxChars)
  }

  const headerModel =
    session?.model ??
    [...messages].reverse().find((message: any) => message?.model?.providerID && message?.model?.id)?.model

  const header = [
    "# OpenCode session handoff",
    "",
    `- session: ${sessionID}`,
    `- title: ${session?.title ?? "untitled"}`,
    `- model: ${headerModel ? `${headerModel.providerID}/${headerModel.id}` : "unknown"}`,
    `- reason: ${reason}`,
    `- created: ${new Date().toISOString()}`,
    "",
    "Continue the work from this transcript in a fresh session.",
    "",
  ].join("\n")

  const stamp = new Date().toISOString().replace(/[:.]/g, "-")
  const file = join(MEMORY_DIR, `handoff-${stamp}.md`)
  const payload = header + body + "\n"
  await mkdir(MEMORY_DIR, { recursive: true, mode: 0o700 })
  await writeFile(file, payload, "utf8")
  await writeFile(join(MEMORY_DIR, "latest-handoff.md"), payload, "utf8")
  await chmod(file, 0o600)
  await chmod(join(MEMORY_DIR, "latest-handoff.md"), 0o600)
  return file
}

export default {
  id: "unlimited-tokens",
  async setup(ctx: any) {
    const options = { ...DEFAULTS, ...(ctx.options ?? {}) }
    const reinstallAt = Number(options.reinstallAt) || 0
    await log(
      `setup start (warn ${options.warnAt}, compact ${options.compactAt}, handoff ${options.handoffAt}, reinstall ${reinstallAt || "off"}, inputLimit ${options.inputLimit})`,
    )

    const compacting = new Set<string>()
    const lastCompact = new Map<string, number>()
    const lastWarn = new Map<string, number>()
    const lastHandoff = new Map<string, number>()
    const lastReinstall = new Map<string, number>()
    // last known usage per session, read by the token_status tool
    const usage = new Map<string, { used: number; limit: number; ratio: number; at: number }>()

    const formatUsage = (sessionID: string, used?: number, limit?: number) => {
      const last = usage.get(sessionID)
      const budget = limit ?? last?.limit ?? options.inputLimit
      const spent = used ?? last?.used
      const ratioValue = spent === undefined ? undefined : spent / budget
      const lines = [
        spent === undefined
          ? `context: no step measured yet (budget ${budget.toLocaleString()})`
          : `context: ${spent.toLocaleString()} / ${budget.toLocaleString()} (${(ratioValue! * 100).toFixed(1)}%)`,
        `thresholds: warn ${(options.warnAt * 100).toFixed(0)}% | compact ${(options.compactAt * 100).toFixed(0)}% | handoff ${(options.handoffAt * 100).toFixed(0)}%` +
          (reinstallAt > 0 ? ` | reinstall ${(reinstallAt * 100).toFixed(0)}%` : " | reinstall off"),
      ]
      if (compacting.has(sessionID)) lines.push("state: compaction in progress")
      else if (last?.at && now() - last.at > 300_000) lines.push("state: stale (no recent step)")
      return lines.join("\n")
    }

    await ctx.tool.transform((editor: any) => {
      editor.add({
        name: "handoff",
        description:
          "Save the current session transcript to a durable Markdown memory file so a fresh session can continue the work without losing context.",
        input: {
          type: "object",
          properties: {
            note: { type: "string", description: "Short reason for taking the handoff" },
          },
          additionalProperties: false,
        },
        options: { codemode: false },
        execute: async (input: any, context: any) => {
          const file = await writeHandoff(ctx, context.sessionID, input?.note ?? "manual")
          await log(`handoff tool wrote ${file}`)
          return {
            content: `Handoff saved to ${file}. Start a new session and reference this file (or the latest-handoff.md copy) to continue.`,
          }
        },
      })

      editor.add({
        name: "token_status",
        description:
          "Report current context usage for this session: used tokens, model input budget, percentage, thresholds, and compaction state.",
        input: { type: "object", properties: {}, additionalProperties: false },
        options: { codemode: false },
        execute: async (_input: any, context: any) => {
          const sessionID = context.sessionID
          const limit = await inputLimit(ctx, sessionID)
          return { content: formatUsage(sessionID, usage.get(sessionID)?.used, limit) }
        },
      })

      editor.add({
        name: "compact_now",
        description:
          "Save a handoff and compact this session immediately, freeing context without closing it.",
        input: { type: "object", properties: {}, additionalProperties: false },
        options: { codemode: false },
        execute: async (_input: any, context: any) => {
          const sessionID = context.sessionID
          if (compacting.has(sessionID)) return { content: "Compaction is already running for this session." }
          const file = await writeHandoff(ctx, sessionID, "manual: compact_now tool").catch(() => "")
          try {
            await ctx.session.compact({ sessionID })
            await log(`manual compaction requested for ${sessionID}`)
            return {
              content:
                `Compaction requested for this session.` + (file ? ` Handoff saved to ${file}.` : ""),
            }
          } catch (error) {
            await log(`manual compaction failed for ${sessionID}: ${String(error)}`)
            return { content: `Compaction failed: ${String(error)}` }
          }
        },
      })
    })

    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          const type = event?.type
          const data = event?.data ?? {}

          if (type === "session.compaction.started") {
            compacting.add(data.sessionID)
            continue
          }
          if (type === "session.compaction.ended" || type === "session.compaction.failed") {
            compacting.delete(data.sessionID)
            lastCompact.set(data.sessionID, now())
            continue
          }
          if (type !== "session.step.ended") continue

          const sessionID = data.sessionID
          if (!sessionID || compacting.has(sessionID)) continue

          const tokens = data.tokens ?? {}
          const used =
            (tokens.input ?? 0) +
            (tokens.cache?.read ?? 0) +
            (tokens.cache?.write ?? 0) +
            (tokens.output ?? 0)
          if (!used) continue

          const limit = await inputLimit(ctx, sessionID)
          const ratio = used / limit
          usage.set(sessionID, { used, limit, ratio, at: now() })
          if (options.verbose || ratio >= options.warnAt) {
            await log(`usage ${sessionID} ${used}/${limit} (${(ratio * 100).toFixed(1)}%)`)
          }

          if (
            ratio >= options.warnAt &&
            now() - (lastWarn.get(sessionID) ?? 0) > options.warnCooldownMs &&
            (await tryLock(`warn-${sessionID}`, options.warnCooldownMs))
          ) {
            lastWarn.set(sessionID, now())
            await log(
              `warning ${sessionID}: context at ${(ratio * 100).toFixed(1)}% (${used}/${limit} tokens).` +
                (reinstallAt > 0
                  ? ` Reinstall at ${(reinstallAt * 100).toFixed(0)}%, fallback compaction at ${(options.compactAt * 100).toFixed(0)}%.`
                  : ` Compaction at ${(options.compactAt * 100).toFixed(0)}%.`),
            )
          }

          const pendingReinstall = reinstallAt > 0 ? await markerExists(sessionID) : false
          let reinstallScheduled = false

          if (
            reinstallAt > 0 &&
            ratio >= reinstallAt &&
            !pendingReinstall &&
            !(await recentlyReinstalled(sessionID, options.reinstallCooldownMs)) &&
            now() - (lastReinstall.get(sessionID) ?? 0) > options.reinstallLockTtlMs &&
            (await tryLock(`reinstall-${sessionID}`, options.reinstallLockTtlMs))
          ) {
            lastReinstall.set(sessionID, now())

            // Save the transcript before the binary is replaced.
            const file = await writeHandoff(ctx, sessionID, "automatic: before uninstall/reinstall").catch(
              (error: any) => {
                void log(`pre-reinstall handoff failed: ${String(error)}`)
                return ""
              },
            )
            if (file) await log(`pre-reinstall handoff wrote ${file}`)

            const marker = join(MEMORY_DIR, `.reinstall-${sessionID}.json`)
            try {
              await writeFile(
                marker,
                JSON.stringify({ sessionID, ratio, used, limit, handoff: file, at: now() }),
                "utf8",
              )
              await chmod(marker, 0o600)
              const pid = spawnReinstall(options.reinstallScript, sessionID)
              reinstallScheduled = true
              await log(
                `auto-reinstall scheduled for ${sessionID} at ${(ratio * 100).toFixed(1)}% (pid ${pid}); waiting for idle`,
              )
            } catch (error) {
              await unlink(marker).catch(() => undefined)
              await log(`auto-reinstall could not start: ${String(error)}`)
            }
          }

          if (pendingReinstall || reinstallScheduled) {
            await log(`reinstall pending for ${sessionID}; skipping compaction`)
            continue
          }

          if (
            ratio >= options.handoffAt &&
            now() - (lastHandoff.get(sessionID) ?? 0) > options.cooldownMs &&
            (await tryLock(`handoff-${sessionID}`, options.cooldownMs))
          ) {
            lastHandoff.set(sessionID, now())
            const file = await writeHandoff(ctx, sessionID, "automatic: context almost full").catch((error: any) => {
              void log(`auto handoff failed: ${String(error)}`)
              return ""
            })
            if (file) await log(`auto handoff wrote ${file}`)
          }

          if (
            ratio >= options.compactAt &&
            now() - (lastCompact.get(sessionID) ?? 0) > options.cooldownMs &&
            (await tryLock(`compact-${sessionID}`, options.cooldownMs))
          ) {
            lastCompact.set(sessionID, now())

            // Save the transcript before it gets summarised, so nothing is lost.
            const file = await writeHandoff(ctx, sessionID, "automatic: before compaction").catch((error: any) => {
              void log(`pre-compaction handoff failed: ${String(error)}`)
              return ""
            })
            if (file) await log(`pre-compaction handoff wrote ${file}`)

            try {
              await ctx.session.compact({ sessionID })
              await log(`compaction requested for ${sessionID} at ${(ratio * 100).toFixed(1)}%`)
            } catch (error) {
              await log(`compaction request failed for ${sessionID}: ${String(error)}`)
            }
          }
        }
      } catch (error) {
        await log(`subscription stopped: ${String(error)}`)
      }
    })()

    return () => {
      controller.abort()
    }
  },
}
