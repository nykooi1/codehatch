# Development

Needs macOS 14 or later and Xcode 16 or later. Run everything from the repository root.

```sh
scripts/run.sh            # build, wrap it as an app, and start it
scripts/run.sh --widget   # and open the stay-on-screen window
```

Its log is at `~/Library/Logs/codehatch.log`.

## Layout

| Folder | What is in it |
| --- | --- |
| `Sources` | The app (Swift, SwiftUI and AppKit) |
| `editor-helper` | The helper extension for Cursor and VS Code |
| `hooks` | The script Claude Code and Codex run |
| `tests` | The tests |
| `scripts` | Build, release and icon scripts |
| `assets` | The app icon and the menu bar mark |
| `docs` | This guide, how it works, and images |

## Tests

```sh
python3 tests/run.py            # about a minute; opens nothing
python3 tests/run.py --apps     # also drives the real Terminal, iTerm2 and VS Code
python3 tests/run.py --live     # also starts real Claude Code and Codex sessions
```

Every test works in a throwaway folder under `~/.codehatch-tests`, made fresh and removed afterwards. The real-app tests
open windows for a few seconds and close only the ones they opened; VS Code must be closed first.

## Sample sessions

`scripts/run.sh -demoMode YES` starts it with made-up sessions only, for screenshots and recordings. If a folder
`~/codehatch-demo/<repo>` exists, picking a sample session brings that folder's editor window forward.

## Releasing

```sh
scripts/release.sh 1.0.0 "What changed, in a sentence."
```

It builds the app, zips it, signs the zip with the update key in your keychain and writes `appcast.xml`. Upload the zip
to a GitHub release tagged `v1.0.0`, and publish `appcast.xml` at `https://codehatch.ai/appcast.xml`. It uploads nothing
itself.

The update key is made once with Sparkle's `generate_keys`, and its public half is `SUPublicEDKey` in `Info.plist`. Back
it up: without it, installed copies can never be updated again.

## The app icon

`swift scripts/make-icon.swift` draws `assets/AppIcon.icns` and `assets/icon.png` from `assets/menu-mark.png`.
