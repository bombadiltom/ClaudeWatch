import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

// Saves the plan limits Claude Code reports with every API response to
//   ~/Library/Caches/de.idiotentruppe.claudewatch/rate-limits/<session id>.json
// in the shape of the status line's `rate_limits`, which ClaudeWatch reads (LiveLimitsReader). Unlike
// the status line, a plugin also runs in Claude Desktop's Code tab. ClaudeWatch installs it from
// Settings (PluginSetup); bump the version in plugin.json with every change, or Claude Code keeps
// the cached copy.

const WINDOWS = ['five_hour', 'seven_day']

/** `{ five_hour: { used_percentage, resets_at }, seven_day: … }`, or undefined without a reading. */
export const limitsJSON = (limits: readonly SessionRateLimit[]) => {
  const out: Record<string, { used_percentage: number; resets_at: string }> = {}
  for (const l of limits) {
    if (WINDOWS.includes(l.kind) && l.resetsAt && Number.isFinite(l.percentUsed)) {
      out[l.kind] = { used_percentage: l.percentUsed, resets_at: l.resetsAt }
    }
  }
  return Object.keys(out).length > 0 ? JSON.stringify(out) : undefined
}


const save = async ($: EngineInterface, limits: readonly SessionRateLimit[]) => {
  try {
    const json = limitsJSON(limits)
    const home = await $.env.get('HOME')
    if (!json || !home?.startsWith('/Users/')) return // nothing to save, or not on a Mac
    const session = (await $.session.id()).replace(/[^A-Za-z0-9_-]/g, '')
    if (!session) return
    const path = `${home}/Library/Caches/de.idiotentruppe.claudewatch/rate-limits/${session}.json`
    // Rewrite even when unchanged: ClaudeWatch dates the reading by the file's modification time.
    await $.fs.write(path, json)
  } catch {
    // Never get in the session's way.
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    try {
      await save($, (await $.session.usage()).rateLimits)
    } catch {}
    return result
  })

  // After each main-thread turn, and whenever a window moves a whole point.
  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    if (e.rateLimits.length > 0) await save($, e.rateLimits)
    return result
  })
}
