# fathomed

A Mac app that shows every coding-agent session you have open and takes you to the one you want.

Push the pointer into the notch, or press ⌥Space, and a panel drops down listing your open Claude Code sessions (Codex support is in progress), grouped by repo. Each one shows what it is, whether it is working, finished, waiting on you or idle, which git branch it is on, and a short recap of where it got to. Click one and its editor window and terminal tab come to the front.

It reads the files those tools already keep on your Mac. It never writes to them, and nothing leaves the machine.

## Status

Early and private. This is a personal project.

- `spike/` is a throwaway test app that the design was shaped on. It works, it has no tests, and it is not the product. The real app will be built alongside it and replace it.

## Running the test app

Needs macOS 14 or later and Xcode's command-line tools.

```sh
cd spike
./run.sh
```

That builds it, wraps it as an app, stops any old copy and starts the new one. Stop it with `pkill -x PortalSpike`.

Useful while developing:

- `./run.sh --widget` also opens the stay-on-screen window.
- `./run.sh --hold` opens the panel without taking the keyboard, so it can be screenshotted.
- Its log is at `~/Library/Logs/fathomed-portal-spike.log`.

## The editor helper

`spike/editor-helper/` is a small extension for Cursor, VS Code and other editors built on VS Code. It does two things and has no interface: it shows a given terminal tab when the app asks, and it tells the app which terminal is in front. Without it the app still brings the right window forward; with it you land on the exact tab.

To build and install it into Cursor:

```sh
cd spike/editor-helper
npx @vscode/vsce package --allow-missing-repository --skip-license
/Applications/Cursor.app/Contents/Resources/app/bin/cursor --install-extension fathomed-portal-helper-*.vsix
```
