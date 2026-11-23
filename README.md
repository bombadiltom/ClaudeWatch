# ClaudeWatch

A menu bar app for macOS 14+ that shows how much of your Claude plan you've used, and what your Claude Code sessions cost: CLI sessions running on Amazon Bedrock, Claude Desktop's Code sessions on your Pro or Max plan, and anything else that writes Claude Code transcripts.

> ClaudeWatch is an independent project. It isn't affiliated with, endorsed by or supported by Anthropic. Claude is a trademark of Anthropic, used here only to say which product the app works with.

- **Plan limits:** the 5-hour and weekly utilization of your Pro/Max plan and when they reset, live from Claude Code (with ClaudeWatch's [plugin or status line](#live-plan-limits)) or from Claude Desktop's Settings › Usage.
- **Menu bar:** your 5-hour plan usage and today's AWS cost, or either one.
- **Tokens and cost:** plan usage in tokens (with its value at API prices), Bedrock usage in dollars.
- **Pinned sessions:** right-click a session to pin it. Pinned sessions get their own rows, with a green dot while they run and a per-model breakdown.
- **Claude Desktop:** totals for the Desktop app's Code sessions, drilling down to projects and then sessions, with the titles Desktop shows.
- **Other sessions:** everything else, by project and session.
- **Periods:** today, the last 7 days, this month, or everything.
- **Budget alert:** an optional notification once today's AWS cost passes an amount you choose.

## Where the numbers come from

Claude Code writes every session to `~/.claude/projects/<folder>/<session-id>.jsonl`. Claude Desktop's Code sessions use the same format. Each API response in those files carries its token usage, so ClaudeWatch:

1. **Reads the transcripts incrementally.** Only new lines are parsed. The parsed state is cached in `~/Library/Caches/de.idiotentruppe.claudewatch`, so a relaunch takes well under a second, even with hundreds of MB of transcripts.
2. **Removes duplicates by message id.** Claude Code writes one line per content block, and forked sessions copy earlier messages.
3. **Prices each request** at Anthropic list prices: input, output, cache reads, and 5-minute and 1-hour cache writes, plus fast mode. Claude Code's own cost figure uses the same rates, Bedrock sessions included.
4. **Adds side requests.** The auto-mode classifier, summaries and titles are billed but don't appear in the transcript as messages. Claude Code keeps a running total per run (`cost-state` records), and ClaudeWatch scales each run's messages up to that total. In short sessions that can be a third of the cost.
5. **Splits by backend** using the message id: `msg_bdrk_…` is Bedrock and counts as **AWS cost**. Anthropic messages count as **plan tokens**, shown with their **plan value**: what that usage would cost at API prices, not something you pay.

**Plan limits** come from two places, whichever is newer. Neither needs a login or network requests:

- **Claude Code** gets your plan's 5-hour and weekly utilization, with their exact reset times, in the headers of every API response. These numbers cover the whole account: Code sessions, Desktop chats, Cowork and claude.ai. ClaudeWatch's Claude Code plugin or its status line saves them for the app (see [Live plan limits](#live-plan-limits)). When you hit a limit, the "limit reached" error in the transcript carries the reset time too, and ClaudeWatch reads that without any setup.
- **Claude Desktop** records the same numbers in `~/Library/Application Support/Claude/plan-usage-history.json` about every 15 minutes while it runs. To bridge the gap, ClaudeWatch adds the plan usage of Claude Code sessions since then (marked ≈), at a rate it learns from Desktop's samples. Usage that isn't in a transcript, from Desktop chats and Cowork, only shows up with the next sample.

ClaudeWatch re-reads both every 5 seconds and shows which one the numbers came from, and when.

### Live plan limits

Open **Settings**. Under **Live plan limits** there are two ways to hand ClaudeWatch the exact numbers. Either is enough, and ClaudeWatch never sets anything up on its own.

- **Claude Code plugin:** runs in every Claude Code session, Claude Desktop's Code tab included. **Set Up** copies the plugin to `~/.claude/claudewatch-plugin/` and installs it with Claude Code's own `claude plugin` commands, so it needs the `claude` command (Claude Code for the terminal). **Remove** uninstalls it. After an update, ClaudeWatch updates the installed plugin.
- **Status line:** runs only in terminal sessions, and also shows the limits under the prompt. **Set Up** copies ClaudeWatch's status line script to `~/.claude/claudewatch-statusline.sh` and adds it to `~/.claude/settings.json`. It changes only the `statusLine` entry and leaves the rest of the file as it was. If you already have a status line, it stays: your command becomes the script's argument, and the script runs it with the same input and shows its output. **Remove** undoes both.

Either one saves each session's numbers to `~/Library/Caches/de.idiotentruppe.claudewatch/rate-limits/`, and ClaudeWatch takes the newest, so any running session keeps it current, while you work in Cowork too. Claude Code only includes the limits for Pro and Max plans, after a session's first response. Sessions on Bedrock or Vertex don't get them.

To install the plugin by hand instead, this repository is a plugin marketplace:

```bash
claude plugin marketplace add bombadiltom/ClaudeWatch
claude plugin install claudewatch@claudewatch
```

To set up the status line by hand, copy the script into Claude Code's folder:

```bash
curl -fsSL https://raw.githubusercontent.com/bombadiltom/ClaudeWatch/main/scripts/claudewatch-statusline.sh -o ~/.claude/claudewatch-statusline.sh
chmod +x ~/.claude/claudewatch-statusline.sh
```

and set it as the status line in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/claudewatch-statusline.sh" }
```

Each terminal session then shows its folder and the limits, like `~/Projects/acme · 5h 12% · 7d 61%`. The script uses only `/usr/bin/plutil`.

**Pinned sessions:** right-click a session in the menu and choose **Pin Session**, or add one in Settings. A session belongs to a pin if its id matches, or if its name (`claude -n <name>`) equals the pin's label, so a pin by name also catches every new session you start with that name.

### Caveats

- **Bedrock regional pricing.** On Bedrock, geographic inference profiles (`eu.`, `us.`, `jp.`, `au.` …) and in-region endpoints cost 10% more than the `global.` profile for current Claude models such as Opus 5.5 ([AWS docs](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)). Transcripts don't record which profile a session used, so set **Bedrock surcharge** to 10 in Settings if you use geographic profiles. Compare with AWS Cost Explorer, which lags up to a day.
- **Deleted transcripts.** Claude Code deletes transcripts older than 30 days (`cleanupPeriodDays`). ClaudeWatch keeps the usage it has already read from them, but anything deleted before ClaudeWatch first ran is gone. To keep transcripts longer, set `"cleanupPeriodDays"` in `~/.claude/settings.json`.
- **Claude Desktop chats** (not Code sessions) aren't stored on your Mac, so their tokens don't appear here. The plan-limit bars include them, because the plan counts all usage together.
- **Without the plugin or the status line, plan limits can trail by 15 minutes or more.** Desktop saves a sample only every 15 minutes, and only while it runs, and it pauses its sampling when you haven't opened its menu bar icon for a day. Claude Code usage since then is estimated, but Desktop chats and Cowork keep their transcripts out of reach (Cowork's run inside its VM), so their usage, and a 5-hour window they started, only show up with Desktop's next sample. The reset time is then inferred from the transcripts ("resets about"). The plugin fixes all of that, as long as a Claude Code session is making requests. Neither file is a documented format, and both may change.
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
