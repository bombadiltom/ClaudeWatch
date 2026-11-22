#!/bin/sh
# ClaudeWatch status line for Claude Code.
#
# With every API response, Claude Code learns your plan's current 5-hour and weekly utilization.
# These are account-wide numbers, so they include Claude Desktop chats, Cowork and claude.ai.
# Claude Code hands them to the status line command. This script saves them where ClaudeWatch
# reads them, so ClaudeWatch shows them within seconds instead of waiting for Claude Desktop's
# next 15-minute sample. It also prints them as the status line, after the session's folder.
#
# Install:
#   cp scripts/claudewatch-statusline.sh ~/.claude/ && chmod +x ~/.claude/claudewatch-statusline.sh
# and add to ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/claudewatch-statusline.sh" }
#
# Uses only /usr/bin/plutil, no jq. It never fails the status line: unreadable input prints nothing.

export LC_ALL=C # printf reads "12.5", not a locale's "12,5"
input=$(cat)
dir="$HOME/Library/Caches/de.idiotentruppe.claudewatch/rate-limits"

get() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" "$2" -o - - 2>/dev/null; }

session=$(get session_id raw) || exit 0
case $session in "" | */* | .*) exit 0 ;; esac

# Claude Code includes rate_limits only for Pro/Max subscribers, after the session's first response.
if limits=$(get rate_limits json); then
    tmp="$dir/.$session.$$"
    mkdir -p "$dir" && printf '%s' "$limits" >"$tmp" && mv -f "$tmp" "$dir/$session.json"
fi

# The session's folder, with the home folder as ~.
line=""
if folder=$(get workspace.current_dir raw) || folder=$(get cwd raw); then
    case $folder in "$HOME" | "$HOME"/*) folder="~${folder#"$HOME"}" ;; esac
    line=$folder
fi
if five=$(get rate_limits.five_hour.used_percentage raw); then
    [ -n "$line" ] && line="$line · "
    line="$line$(printf '5h %.0f%%' "$five")"
fi
if week=$(get rate_limits.seven_day.used_percentage raw); then
    [ -n "$line" ] && line="$line · "
    line="$line$(printf '7d %.0f%%' "$week")"
fi
[ -n "$line" ] && printf '%s\n' "$line"
exit 0
