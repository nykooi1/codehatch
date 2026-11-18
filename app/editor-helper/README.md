# codehatch helper

A small extension for Cursor, VS Code and other editors built on VS Code. It has no interface. When codehatch asks, it
brings a given terminal tab to the front, reopens a closed Claude Code or Codex session in a new terminal in its project,
or brings the Claude Code panel forward. It also notes, in a small file on your Mac, which terminal is in front, so
codehatch can highlight the session you are in. It makes no network connections.

codehatch installs it for you. To build it by hand: `npx @vscode/vsce package`, then install the `.vsix` from the editor.
