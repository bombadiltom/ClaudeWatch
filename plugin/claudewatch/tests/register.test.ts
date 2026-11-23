import { expect, test } from 'claude-code/testing'

const LIMITS = [
  { kind: 'five_hour', percentUsed: 77, resetsAt: '2026-11-23T10:17:00.000Z' },
  { kind: 'seven_day', percentUsed: 9.5, resetsAt: '2026-11-30T02:00:00.000Z' },
  { kind: 'spend_limit', percentUsed: 3 },
]

const engine = (on: any, home: string | undefined, writes: { path: string; text: string }[]) => {
  on('env.get', () => ({ value: home }))
  on('session.id', () => ({ value: '11111111-2222-4333-8444-555555555555' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 200000 }, rateLimits: LIMITS } }))
  on('fs.write', (_: any, e: any) => (writes.push({ path: e.path, text: e.text }), { value: undefined }))
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
}

test('saves the 5-hour and weekly limits where ClaudeWatch reads them', async ($, on) => {
  const writes: { path: string; text: string }[] = []
  engine(on, '/Users/acme', writes)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  expect(writes.length).toBe(1)
  expect(writes[0]!.path).toBe(
    '/Users/acme/Library/Caches/de.idiotentruppe.claudewatch/rate-limits/11111111-2222-4333-8444-555555555555.json')
  expect(JSON.parse(writes[0]!.text)).toEqual({
    five_hour: { used_percentage: 77, resets_at: '2026-11-23T10:17:00.000Z' },
    seven_day: { used_percentage: 9.5, resets_at: '2026-11-30T02:00:00.000Z' },
  })
})

test('writes nothing off a Mac', async ($, on) => {
  const writes: { path: string; text: string }[] = []
  engine(on, '/home/acme', writes)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(writes.length).toBe(0)
})
