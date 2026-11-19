"""Tests against the real apps: Terminal, iTerm2, Cursor and VS Code. Run with: python3 tests/run.py --apps

These open real windows on your screen for a few seconds and close them again. They only ever touch windows and
processes they created themselves, which they recognise by the terminal device each one runs on. The first run may
show a macOS prompt asking to let the app that started the tests control Terminal or iTerm2.
"""
import os, subprocess, time

from run import APP, alive, eq


def osa(source, *args):
    r = subprocess.run(["/usr/bin/osascript", "-e", source, *args], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise AssertionError("AppleScript failed: " + r.stderr.strip()[:200])
    return r.stdout.strip()


def on_tty(tty, name=None):
    """Process ids on a terminal device, optionally only those running a given program."""
    out = subprocess.run(["/bin/ps", "-t", tty.replace("/dev/", ""), "-o", "pid=,comm="], capture_output=True, text=True).stdout
    rows = [l.split(None, 1) for l in out.splitlines() if l.strip()]
    return [int(p) for p, c in rows if name is None or os.path.basename(c).lstrip("-") == name]


def wait(what, check, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        v = check()
        if v:
            return v
        time.sleep(0.4)
    raise AssertionError("timed out waiting for " + what)


SCRIPTS = {
    "terminal": {
        "open": 'on run argv\n tell application "Terminal"\n set t to do script (item 1 of argv)\n delay 0.6\n return tty of t\n end tell\nend run',
        "front": 'tell application "Terminal" to return tty of selected tab of front window',
        "close": 'on run argv\n tell application "Terminal"\n repeat with w in windows\n try\n if (tty of selected tab of w) is (item 1 of argv) then close w saving no\n end try\n end repeat\n end tell\nend run',
    },
    "iterm": {
        "open": 'on run argv\n tell application id "com.googlecode.iterm2"\n set w to (create window with default profile)\n tell current session of w to write text (item 1 of argv)\n delay 0.8\n return tty of current session of w\n end tell\nend run',
        "front": 'tell application id "com.googlecode.iterm2" to return tty of current session of current window',
        "close": 'on run argv\n tell application id "com.googlecode.iterm2"\n repeat with w in windows\n try\n repeat with t in tabs of w\n repeat with s in sessions of t\n if (tty of s) is (item 1 of argv) then close s\n end repeat\n end repeat\n end try\n end repeat\n end tell\nend run',
    },
}


IDS = {
    "terminal": 'tell application "Terminal"\n set out to ""\n repeat with w in windows\n set out to out & (id of w as text) & " "\n end repeat\n return out\n end tell',
    "iterm": 'tell application id "com.googlecode.iterm2"\n set out to ""\n repeat with w in windows\n set out to out & (id of w as text) & " "\n end repeat\n return out\n end tell',
}
CLOSE_ID = {
    "terminal": 'on run argv\n tell application "Terminal" to close (window id ((item 1 of argv) as integer)) saving no\nend run',
    "iterm": 'on run argv\n tell application id "com.googlecode.iterm2" to close (first window whose id is ((item 1 of argv) as integer))\nend run',
}


def drive(sb, kind, name):
    """Clicking a session lands on its exact tab; resuming opens a new one in the right folder; closing ends it."""
    sc = SCRIPTS[kind]
    repo = sb.repo("codehatch-test-" + kind)
    ttys = []
    # A window standing in for one of yours: opened before the test proper, and it must still be there at the end.
    bystander = osa(sc["open"], "cd '%s' && echo this window is not part of the test" % repo)
    before = set(osa(IDS[kind]).split())   # the windows that were already open: these are never touched
    try:
        first = osa(sc["open"], "cd '%s' && sleep 911" % repo); ttys.append(first)
        second = osa(sc["open"], "cd '%s' && sleep 912" % repo); ttys.append(second)
        if osa(sc["front"]) == first:
            raise AssertionError("the first window is already in front, so the test could not tell whether the jump worked")
        pid = wait("the first window's process", lambda: (on_tty(first, "sleep") or [None])[0])
        shell = wait("the first window's shell", lambda: (on_tty(first, "zsh") or on_tty(first, "bash") or [None])[0])

        out = subprocess.run([APP, "--focus-terminal", str(pid)], capture_output=True, text=True, timeout=60).stdout.strip()
        eq(out, "ok %s %s" % (kind, first), "what the app reported")
        eq(osa(sc["front"]), first, "the first window is now in front")
        # The session you are in is found by asking which tab is in front; the app's own answer must be that tab.
        mine = subprocess.run([APP, "--front-tab", kind], capture_output=True, text=True, timeout=60).stdout.strip()
        eq(mine, first, "the tab the app says is in front")

        marker = os.path.join(repo, "resumed.txt")
        subprocess.run([APP, "--terminal-run", kind, repo, "tty > resumed.txt"], timeout=60)
        wait("the command to run in a new tab, in the folder", lambda: os.path.exists(marker) and open(marker).read().strip(), timeout=45)
        third = open(marker).read().strip(); ttys.append(third)
        if third in (first, second):
            raise AssertionError("resume reused an existing tab instead of opening a new one")

        subprocess.run([APP, "--close-and-exit", str(pid)], timeout=30)
        time.sleep(0.5)
        if alive(pid) or alive(shell):
            raise AssertionError("the session or its shell is still running after close")
        if not on_tty(bystander):
            raise AssertionError("a window that was open before the test, and not part of it, was closed")
        gone = before - set(osa(IDS[kind]).split())
        if gone:
            raise AssertionError("windows that were open before the test are gone: %s" % sorted(gone))
    finally:
        for tty in ttys:  # end whatever is still running in our tabs, then close just those
            for p in on_tty(tty):
                try:
                    os.kill(p, 9)
                except OSError:
                    pass
        time.sleep(0.5)
        for tty in ttys:
            try:
                osa(sc["close"], tty)
            except AssertionError:
                pass
        # and any window that appeared during the test and is still open, whatever became of it
        for wid in set(osa(IDS[kind]).split()) - before:
            try:
                osa(CLOSE_ID[kind], wid)
            except AssertionError:
                pass
        for p in on_tty(bystander):   # last of all, the stand-in window, which the test itself opened
            try:
                os.kill(p, 9)
            except OSError:
                pass
        time.sleep(0.4)
        try:
            osa(sc["close"], bystander)
        except AssertionError:
            pass


def test_app_terminal(sb):
    """Terminal: clicking a session lands on its exact window; resuming opens a new one in the right folder; closing ends it."""
    drive(sb, "terminal", "Terminal")


def test_app_iterm(sb):
    """iTerm2: clicking a session lands on its exact tab; resuming opens a new one in the right folder; closing ends it."""
    if not os.path.isdir("/Applications/iTerm.app"):
        raise AssertionError("iTerm2 is not installed")
    drive(sb, "iterm", "iTerm2")


CODE = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
NOTE = os.path.join(os.path.expanduser("~"), ".codehatch", "active-terminal.json")


def note():
    try:
        import json
        return json.load(open(NOTE))
    except (OSError, ValueError):
        return {}


def test_app_vscode(sb):
    """VS Code, for real: the helper resumes a session in a new terminal in the right folder, and lands on an exact tab."""
    if not os.path.exists(CODE):
        raise AssertionError("VS Code is not installed")
    # Anchored at the start, so it only matches VS Code itself and not some other command that mentions its path.
    running = lambda: subprocess.run(["pgrep", "-f", "^/Applications/Visual Studio Code.app/Contents/"], capture_output=True).returncode == 0
    for _ in range(40):   # a copy from an earlier test run can take a few seconds to finish closing
        if not running():
            break
        time.sleep(0.5)
    if running():
        raise AssertionError("VS Code is already open. Quit it first: the test needs to be the only copy running, so its links reach the test window.")
    import glob, json, uuid
    vsix = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "editor-helper", "codehatch-helper-*.vsix")))
    if not vsix:
        raise AssertionError("the helper has not been packaged (no .vsix in editor-helper)")
    repo = os.path.realpath(sb.repo("codehatch-test-vscode"))
    data, exts = sb.path("vscode-data"), sb.path("vscode-extensions")   # a throwaway profile: your own VS Code setup is not touched
    os.makedirs(os.path.join(data, "User"))
    with open(os.path.join(data, "User", "settings.json"), "w") as f:
        json.dump({"security.workspace.trust.enabled": False, "extensions.confirmedUriHandlerExtensionIds": ["codehatch.codehatch-helper"],
                   "update.mode": "none", "telemetry.telemetryLevel": "off", "workbench.startupEditor": "none", "window.restoreWindows": "none"}, f)
    base = [CODE, "--user-data-dir", data, "--extensions-dir", exts]
    r = subprocess.run(base + ["--install-extension", vsix[-1]], capture_output=True, text=True, timeout=120)
    if "successfully installed" not in r.stdout:
        raise AssertionError("could not install the helper into the test profile: " + (r.stdout + r.stderr)[-200:])
    saved = open(NOTE).read() if os.path.exists(NOTE) else None
    link = lambda path, **q: subprocess.run(["/usr/bin/open", "-g", "vscode://codehatch.codehatch-helper/%s?%s" % (path, "&".join("%s=%s" % (k, subprocess.run(["python3", "-c", "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=''))", str(v)], capture_output=True, text=True).stdout.strip()) for k, v in q.items()))])
    try:
        subprocess.run(base + ["--new-window", repo], capture_output=True, timeout=60)
        wait("VS Code to open and the helper to report in", lambda: note().get("folder") == repo, timeout=60)

        ids = [str(uuid.uuid4()), str(uuid.uuid4())]
        link("resume", tool="claude", id=ids[0], cwd=repo)
        first = wait("the first resumed session's terminal", lambda: note().get("folder") == repo and note().get("pid"), timeout=30)
        link("resume", tool="claude", id=ids[1], cwd=repo)
        second = wait("the second resumed session's terminal", lambda: note().get("pid") not in (None, first) and note().get("pid"), timeout=30)
        cwd = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(first), "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
        if os.path.realpath(repo) not in cwd:
            raise AssertionError("the resumed session's terminal is not in the session's folder")

        link("focus", pids=first)
        wait("the first terminal tab to come to the front", lambda: note().get("pid") == first, timeout=20)
        link("focus", pids=second)
        wait("the second terminal tab to come to the front", lambda: note().get("pid") == second, timeout=20)

        before = note().get("pid")
        link("resume", tool="claude", id="not-a-session-id; rm -rf ~", cwd=repo)       # must be refused
        link("resume", tool="claude", id=str(uuid.uuid4()), cwd="/tmp")               # not this window's folder: refused
        time.sleep(3)
        eq(note().get("pid"), before, "links with a bad id or another folder open nothing")
    finally:
        subprocess.run(["pkill", "-f", "user-data-dir " + data], capture_output=True)   # only the copy started here
        for _ in range(30):
            if subprocess.run(["pgrep", "-f", data], capture_output=True).returncode != 0:
                break
            time.sleep(0.5)
        if saved is not None:
            open(NOTE, "w").write(saved)   # put back the note about your own front terminal


TESTS = [test_app_terminal, test_app_iterm, test_app_vscode]
