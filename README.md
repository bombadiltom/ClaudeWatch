# TokenTally

A menu bar app for macOS 14+ that shows what your Claude Code sessions cost: CLI sessions running on Amazon Bedrock, Claude Desktop's Code sessions on your Pro or Max plan, and anything else that writes Claude Code transcripts.

- **Menu bar:** today's AWS cost (or AWS cost plus plan value), and optionally your 5-hour plan usage.
- **Pinned sessions:** CLI sessions you start with a fixed `--session-id` get their own rows, with a green dot while they run and a per-model breakdown.
- **Claude Desktop:** totals for the Desktop app's Code sessions, drilling down to projects and then sessions, with the titles Desktop shows.
- **Other sessions:** everything else, by project and session.
- **Periods:** today, the last 7 days, this month, or everything.
- **Budget alert:** an optional notification once today's AWS cost passes an amount you choose.
- **Plan limits (optional):** the 5-hour and weekly utilization of your Pro/Max plan, as Claude Code's `/usage` shows it.

## Where the numbers come from

Claude Code writes every session to `~/.claude/projects/<folder>/<session-id>.jsonl`. Claude Desktop's Code sessions use the same format. Each API response in those files carries its token usage, so TokenTally:

1. **Reads the transcripts incrementally.** Only new lines are parsed. The parsed state is cached in `~/Library/Caches/de.lorenz-unna.tokentally`, so a relaunch takes well under a second, even with hundreds of MB of transcripts.
2. **Removes duplicates by message id.** Claude Code writes one line per content block, and forked sessions copy earlier messages.
3. **Prices each request** at Anthropic list prices: input, output, cache reads, and 5-minute and 1-hour cache writes, plus fast mode. Claude Code's own cost figure uses the same rates, Bedrock sessions included.
4. **Adds side requests.** The auto-mode classifier, summaries and titles are billed but don't appear in the transcript as messages. Claude Code keeps a running total per run (`cost-state` records), and TokenTally scales each run's messages up to that total. In short sessions that can be a third of the cost.
5. **Splits by backend** using the message id: `msg_bdrk_…` is Bedrock and counts as **AWS cost**. Anthropic messages count as **plan value**: what your plan usage would cost at API prices, not something you pay.

Matching pinned sessions: a session belongs to a pin if its id matches, or if its name (`claude -n <name>`) equals the pin's label. On first launch TokenTally imports pins from `~/.zshrc`. It looks for variables that hold a UUID, and takes the label from a call like `_claude_pinned acme-main "$ACME_MAIN_ID"` or else from the variable name.

### Caveats

- **Bedrock regional pricing.** AWS documents that global cross-Region inference for Claude Sonnet 4.5 costs about 10% less than geographic (`eu.`, `us.`, `apac.`) inference profiles ([AWS docs](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)). If your AWS bill shows a premium over Anthropic list prices, set **Bedrock surcharge** in Settings.
- **Claude Desktop chats** (not Code sessions) aren't stored on your Mac, so they don't appear here. The plan-limit bars cover them, because the plan counts all usage together.
- **Plan limits** use the subscription login Claude Code keeps in the keychain (`Claude Code-credentials`), the same one `/usage` uses. macOS asks once whether TokenTally may read it. If you only run Claude Code on Bedrock, that login can expire. Run `claude` once without the Bedrock variables to refresh it. The endpoint isn't a documented public API and may change.
- **Prices** are built in (`TokenTally/Pricing.swift`). A model that's missing shows as "unpriced" instead of guessing.

## Install with Homebrew

```bash
brew tap bombadiltom/tap
brew trust --cask bombadiltom/tap/tokentally
brew install --cask bombadiltom/tap/tokentally
```

Homebrew 7 only loads casks from third-party taps once you trust them, which is what the `brew trust` line does. The app is signed with a Developer ID and notarized by Apple.

## Build

```bash
xcodegen generate
xcodebuild -project TokenTally.xcodeproj -scheme TokenTally -configuration Release -derivedDataPath build build
open build/Build/Products/Release/TokenTally.app
```

Run the tests with `xcodebuild -project TokenTally.xcodeproj -scheme TokenTally -derivedDataPath build test`. To render the menu with your own data to a PNG (no clicking needed), add `TEST_RUNNER_TOKENTALLY_SNAPSHOT_DIR=/some/dir` and `-only-testing:TokenTallyTests/SnapshotTests`.

## Releasing

Commit and push, then run:

```bash
scripts/release.sh 1.1
```

This tags the commit as `v1.1` and pushes the tag. The [Release action](.github/workflows/release.yml) builds, signs and notarizes the app, publishes a GitHub release and updates the cask in [bombadiltom/homebrew-tap](https://github.com/bombadiltom/homebrew-tap).

- `scripts/release.sh 1.1 --build-only` builds and notarizes locally without publishing.
- `scripts/release.sh 1.1 --publish-existing-tag` (with the tag checked out) does the action's work locally.
- The action needs repository secrets. Run `scripts/setup-ci-secrets.sh` yourself once to set them. Local releases need a Developer ID certificate, a `notarytool` keychain profile (`BluetoothBatteryWatch` by default, override with `NOTARY_PROFILE`) and `gh` logged in as `bombadiltom`.
