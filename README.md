# ClaudeWatch

A menu bar app for macOS 14+ that shows how much of your Claude plan you've used, and what your Claude Code sessions cost: CLI sessions running on Amazon Bedrock, Claude Desktop's Code sessions on your Pro or Max plan, and anything else that writes Claude Code transcripts.

> ClaudeWatch is an independent project. It isn't affiliated with, endorsed by or supported by Anthropic. Claude is a trademark of Anthropic, used here only to say which product the app works with.

- **Plan limits:** the 5-hour and weekly utilization of your Pro/Max plan, as Claude Desktop's Settings › Usage shows it.
- **Menu bar:** your 5-hour plan usage and today's AWS cost, or either one.
- **Tokens and cost:** plan usage in tokens (with its value at API prices), Bedrock usage in dollars.
- **Pinned sessions:** right-click a session to pin it. Pinned sessions get their own rows, with a green dot while they run and a per-model breakdown.
- **Claude Desktop:** totals for the Desktop app's Code sessions, drilling down to projects and then sessions, with the titles Desktop shows.
- **Other sessions:** everything else, by project and session.
- **Periods:** today, the last 7 days, this month, or everything.
- **Budget alert:** an optional notification once today's AWS cost passes an amount you choose.

## Where the numbers come from

Claude Code writes every session to `~/.claude/projects/<folder>/<session-id>.jsonl`. Claude Desktop's Code sessions use the same format. Each API response in those files carries its token usage, so ClaudeWatch:

1. **Reads the transcripts incrementally.** Only new lines are parsed. The parsed state is cached in `~/Library/Caches/de.lorenz-unna.claudewatch`, so a relaunch takes well under a second, even with hundreds of MB of transcripts.
2. **Removes duplicates by message id.** Claude Code writes one line per content block, and forked sessions copy earlier messages.
3. **Prices each request** at Anthropic list prices: input, output, cache reads, and 5-minute and 1-hour cache writes, plus fast mode. Claude Code's own cost figure uses the same rates, Bedrock sessions included.
4. **Adds side requests.** The auto-mode classifier, summaries and titles are billed but don't appear in the transcript as messages. Claude Code keeps a running total per run (`cost-state` records), and ClaudeWatch scales each run's messages up to that total. In short sessions that can be a third of the cost.
5. **Splits by backend** using the message id: `msg_bdrk_…` is Bedrock and counts as **AWS cost**. Anthropic messages count as **plan tokens**, shown with their **plan value**: what that usage would cost at API prices, not something you pay.

**Plan limits** come from `~/Library/Application Support/Claude/plan-usage-history.json`, where Claude Desktop records your 5-hour and weekly utilization about every 15 minutes while it runs. ClaudeWatch reads the newest sample and shows how old it is. It needs no login and makes no network requests.

**Pinned sessions:** right-click a session in the menu and choose **Pin Session**, or add one in Settings. A session belongs to a pin if its id matches, or if its name (`claude -n <name>`) equals the pin's label, so a pin by name also catches every new session you start with that name.

### Caveats

- **Bedrock regional pricing.** AWS documents that global cross-Region inference for Claude Sonnet 4.5 costs about 10% less than geographic (`eu.`, `us.`, `apac.`) inference profiles ([AWS docs](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)). If your AWS bill shows a premium over Anthropic list prices, set **Bedrock surcharge** in Settings.
- **Claude Desktop chats** (not Code sessions) aren't stored on your Mac, so their tokens don't appear here. The plan-limit bars include them, because the plan counts all usage together.
- **Plan limits trail Claude Desktop by up to 15 minutes.** Desktop's own Usage view fetches fresh numbers from claude.ai, but it saves them to disk only every 15 minutes, so during heavy use ClaudeWatch can show a few percent less. The menu shows the time of the sample. Without Desktop running, the bars keep the last sample. Desktop doesn't save when the windows reset, so ClaudeWatch can't show reset times. The file isn't a documented format and may change.
- **Prices** are built in (`ClaudeWatch/Pricing.swift`). A model that's missing shows as "unpriced" instead of guessing.

## Install with Homebrew

```bash
brew tap bombadiltom/tap
brew trust --cask bombadiltom/tap/claudewatch
brew install --cask bombadiltom/tap/claudewatch
```

Homebrew 7 only loads casks from third-party taps once you trust them, which is what the `brew trust` line does. The app is signed with a Developer ID and notarized by Apple.

## Build

```bash
xcodegen generate
xcodebuild -project ClaudeWatch.xcodeproj -scheme ClaudeWatch -configuration Release -derivedDataPath build build
open build/Build/Products/Release/ClaudeWatch.app
```

Run the tests with `xcodebuild -project ClaudeWatch.xcodeproj -scheme ClaudeWatch -derivedDataPath build test`. To render the menu with your own data to a PNG (no clicking needed), add `TEST_RUNNER_CLAUDEWATCH_SNAPSHOT_DIR=/some/dir` and `-only-testing:ClaudeWatchTests/SnapshotTests`.

## Releasing

Commit and push, then run:

```bash
scripts/release.sh 1.1
```

This tags the commit as `v1.1` and pushes the tag. The [Release action](.github/workflows/release.yml) builds, signs and notarizes the app, publishes a GitHub release and updates the cask in [bombadiltom/homebrew-tap](https://github.com/bombadiltom/homebrew-tap).

- `scripts/release.sh 1.1 --build-only` builds and notarizes locally without publishing.
- `scripts/release.sh 1.1 --publish-existing-tag` (with the tag checked out) does the action's work locally.
- The action needs repository secrets. Run `scripts/setup-ci-secrets.sh` yourself once to set them. Local releases need a Developer ID certificate, a `notarytool` keychain profile (`BombadilTom` by default, override with `NOTARY_PROFILE`) and `gh` logged in as `bombadiltom`.
