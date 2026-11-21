# ClaudeWatch

A macOS 14+ menu bar app (SwiftUI `MenuBarExtra`, `.window` style, Swift 6, `LSUIElement`). It shows Claude
plan limits and the usage and cost of Claude Code sessions, read from local files only. The README describes
the features and the data sources. This file covers what you need to change the app safely.

## Build and test

- The Xcode project is generated: edit `project.yml`, never `ClaudeWatch.xcodeproj` (it's git-ignored). Run
  `xcodegen generate` after adding, removing or renaming files.
- Tests: `xcodebuild -project ClaudeWatch.xcodeproj -scheme ClaudeWatch -derivedDataPath build test`.
- To see the UI without clicking the menu bar, render it with your real data to PNGs (menu per period, menu bar
  label, Settings):
  `TEST_RUNNER_CLAUDEWATCH_SNAPSHOT_DIR=<dir> xcodebuild … test -only-testing:ClaudeWatchTests/SnapshotTests`.
  Look at the images before calling a UI change done. Scrollers and hover states don't show in them.
- Tests that need a `UsageStore` must pass `UsageStore(defaults: UserDefaults(suiteName: …))`. The test host is
  the app itself, so `.standard` is the user's real settings.

## Where the data comes from

| Data | Source | Code |
|---|---|---|
| Tokens, cost per request | `~/.claude/projects/**/*.jsonl` (Claude Code and Desktop Code sessions) | `TranscriptScanner` |
| Side requests (classifier, titles) | `cost-state` records in the same files | `SideRequests` |
| Live sessions, names | `~/.claude/sessions/<pid>.json` | `SessionDirectory` |
| Desktop session titles | `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` | `SessionDirectory` |
| Plan limits (5-hour, weekly) | `~/Library/Application Support/Claude/plan-usage-history.json` | `PlanUsageReader` |

- None of these formats are documented. Parse loosely and degrade quietly: return nil or skip the record,
  never crash.
- **Deduplication:** by message id, keeping the earliest copy. Claude Code writes one line per content block,
  and forks copy earlier messages.
- **Backend:** taken from the message id prefix. `msg_bdrk_` is Bedrock (AWS cost), `msg_vrtx_` is Vertex, and
  anything else counts against the plan (plan tokens, valued at API list price).
- **Bedrock regional premium:** transcripts don't record which inference profile a session used. Geographic
  and in-region profiles cost 10% more than global ones, which is the user-set "Bedrock surcharge".
- **Plan limits:** Desktop saves a sample only every 15 minutes. `PlanEstimator` adds the plan usage since the
  last sample, at a %-per-dollar rate learned from Desktop's own samples. It also infers the 5-hour reset
  from the first plan request after the previous window ended. Don't read Desktop's cookies or Claude Code's
  keychain login to get live numbers.
- **Deleted transcripts:** Claude Code deletes transcripts after `cleanupPeriodDays`. The scanner keeps entries
  of files that disappeared, so totals don't shrink.
- **Scanner cache:** the scanner reads incrementally (byte offset and inode per file) and caches its state in
  `~/Library/Caches/de.lorenz-unna.claudewatch/`. If you change what it stores per entry, bump
  `Cache.currentVersion` so old caches are discarded.

## Prices

`Pricing.swift` holds Anthropic list prices per bare model id; `normalize()` strips region prefixes and date
suffixes. An unknown model counts as "unpriced"; never guess its price. When adding a model, take the
prices from the claude-api skill or Anthropic's pricing page, and add a test case if it has a special tier.

## UI rules learned the hard way

- **Menu bar label:** it's drawn as one fixed-width `NSImage` (`MenuBarImage`). The popover hangs under the
  status item, so any width change moves the whole menu sideways. Keep every slot as wide as its widest
  possible text.
- **Period picker:** it's a custom fixed-width control (`PeriodPicker`). The native segmented `Picker`
  overflowed its frame and resized its segments when the selection changed.
- **Scroll view:** it spans the full popover width, and the content is inset inside it, so the scroller sits
  at the edge instead of over the numbers.
- **Bindings in `ForEach`:** use id-based bindings (`SettingsView.binding`). Reading a binding inside a closure
  that mutates the same array crashes with an exclusivity violation.
- **Time-relative text:** wrap it in `TimelineView`. Otherwise it freezes until the data changes.

## Privacy

The repo is public. Test fixtures and docs use placeholders (acme, globex, made-up UUIDs), never real
customer names, session ids, paths or emails. Release scripts keep `<apple-id>` placeholders.

## Releasing

Commit and push to `main`, then `scripts/release.sh <version>`. It tags `v<version>`, and the Release action
builds, signs, notarizes, publishes the GitHub release and updates `Casks/claudewatch.rb` in
`bombadiltom/homebrew-tap`. After it finishes:

- Download the zip and check it with `spctl -a -vv`.
- Compare its sha256 with the cask.
- Upgrade with `brew upgrade --cask claudewatch`.

Git and GitHub details:

- Use the SSH remote. The `bombadiltom` gh token can't push changes to `.github/workflows` over HTTPS.
- For `gh`, use `GH_TOKEN=$(gh auth token --user bombadiltom)`. The default gh account is a different one.
- Local releases (`--build-only`, `--publish-existing-tag`) clone the tap into `build/tap`, so commits use this
  repo's git identity. Keep it there, not in a temp folder.
