#!/bin/bash
# codehatch's hook. Claude Code and Codex run it when a session starts, gets a prompt, asks for
# permission, finishes a turn, or ends. It notes the event in a small file under ~/.codehatch/live
# and exits. It prints nothing and always exits 0, so it can never block or change a session.
#
#   usage: codehatch-hook.sh <claude|codex> <event name>     (the tool's own JSON arrives on stdin)
#
# One file per session, replaced on every event, so the file always holds the latest one. Only the
# session's id, its folder and the kind of notification are kept; the prompt and tool details that
# the tool also sends are not written anywhere.
tool="$1"; event="$2"
dir="$HOME/.codehatch/live"
mkdir -p "$dir" 2>/dev/null || exit 0
# Read what the tool sends, but never wait for it: if a line does not arrive within a second (a session being shut
# down with its window may never finish sending), carry on with what has come. A hook that waits holds up the tool.
in=""
while IFS= read -r -t 1 line || [ -n "$line" ]; do in="$in$line"; line=""; done 2>/dev/null
pick() { printf '%s' "$in" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
sid=$(pick session_id)
[ -n "$sid" ] || sid="pid-$PPID"
case "$sid" in *[!A-Za-z0-9._-]*) exit 0;; esac
out="$dir/$tool-$sid.json"
tmp="$dir/.$tool-$sid.$$"
printf '{"tool":"%s","event":"%s","pid":%s,"at":%s,"session_id":"%s","cwd":"%s","kind":"%s"}\n' \
  "$tool" "$event" "$PPID" "$(date +%s)" "$sid" "$(pick cwd)" "$(pick notification_type)" > "$tmp" 2>/dev/null \
  && mv -f "$tmp" "$out" 2>/dev/null
exit 0
