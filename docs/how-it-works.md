# How codehatch works

## Finding sessions

- **Claude Code** keeps a small file per running session in `~/.claude/sessions` (its process, folder and state) and a
  record of each conversation under `~/.claude/projects`. codehatch reads both: the first says which sessions are open
  and what they are doing, the second gives the title, branch, recap and last messages.
- **Codex** keeps a log per session under `~/.codex/sessions` and a small database at `~/.codex/state_*.sqlite`.
  Running Codex sessions are found from the list of programs running on the Mac and matched to their logs by folder and
  start time.
- **Recently closed** sessions are the conversations whose program is no longer running, from the last 14 days by default.

codehatch only reads these. The one exception is its own hook entries (below), which it adds and removes.

## Noticing changes

- **Hooks.** With live updates on, Claude Code and Codex run `hooks/codehatch-hook.sh` when a session starts, gets a
  prompt, asks for permission, finishes a turn or ends. The script writes one small file per session to
  `~/.codehatch/live` recording which session, which event and when, and nothing else. It never blocks the tool: it waits
  at most a second for its input and always exits successfully.
- **File watching.** codehatch also watches the session folders, so it works without hooks, a little more slowly.

## Going to a session

- **Terminal and iTerm2:** codehatch finds the tab by the terminal device the session runs on, and brings it forward
  through AppleScript. The first time, macOS asks to let codehatch control that app.
- **Cursor and VS Code:** the helper extension (`editor-helper`) receives a link from codehatch and shows the
  terminal tab whose process matches. Without the helper, codehatch brings the right window forward but cannot pick the tab.
- **Resuming** a closed session opens a new terminal in its folder and runs `claude --resume <id>` or
  `codex resume <id>`. The command is built from a checked session id, never taken from the link.

## Updates

codehatch uses [Sparkle](https://sparkle-project.org). Once a day it fetches `https://codehatch.ai/appcast.xml`, and an
update is installed only if it is signed with the project's key. `scripts/release.sh` builds, signs and packages a release
and writes that feed.

## Performance

The notch is watched by listening for pointer movement, not by asking where the pointer is on a timer, so codehatch does
nothing while the pointer is still. Session files are read only when they change. Measured on an Apple-silicon MacBook:
under 1% of one processor core while sessions are working, about 37 MB of memory.
