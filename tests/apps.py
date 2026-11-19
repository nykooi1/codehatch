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
    running = lambda: subprocess.run(["pgrep", "-f", "^/Applications/Visual Studio Code.app/Contents/MacOS/"], capture_output=True).returncode == 0
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


WINDOWS = os.path.join(os.path.expanduser("~"), ".codehatch", "windows")


def window_notes():
    """The helper's notes of the editor windows: file name -> what it says."""
    import glob, json
    out = {}
    for f in glob.glob(os.path.join(WINDOWS, "*.json")):
        try:
            out[os.path.basename(f)] = json.load(open(f))
        except (OSError, ValueError):
            pass
    return out


def test_app_editor_windows(sb):
    """A click on a session in an editor brings back the window it is in, never a new one: also when the session was
    started in a subfolder, in a folder no window has open, or in the window that is not in front. Two real VS Code
    windows, in a throwaway profile."""
    if not os.path.exists(CODE):
        raise AssertionError("VS Code is not installed")
    running = lambda: subprocess.run(["pgrep", "-f", "^/Applications/Visual Studio Code.app/Contents/MacOS/"], capture_output=True).returncode == 0
    for _ in range(40):
        if not running():
            break
        time.sleep(0.5)
    if running():
        raise AssertionError("VS Code is already open. Quit it first: the test needs to be the only copy running, so its links reach the test windows.")
    import glob, json, uuid
    vsix = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "editor-helper", "codehatch-helper-*.vsix")))
    a, b = os.path.realpath(sb.repo("codehatch-test-a")), os.path.realpath(sb.repo("codehatch-test-b"))
    sub = os.path.join(a, "app", "src")
    os.makedirs(sub)
    data, exts = sb.path("vscode-data"), sb.path("vscode-extensions")
    os.makedirs(os.path.join(data, "User"))
    with open(os.path.join(data, "User", "settings.json"), "w") as f:
        json.dump({"security.workspace.trust.enabled": False, "extensions.confirmedUriHandlerExtensionIds": ["codehatch.codehatch-helper"],
                   "update.mode": "none", "telemetry.telemetryLevel": "off", "workbench.startupEditor": "none", "window.restoreWindows": "none"}, f)
    base = [CODE, "--user-data-dir", data, "--extensions-dir", exts]
    r = subprocess.run(base + ["--install-extension", vsix[-1]], capture_output=True, text=True, timeout=120)
    if "successfully installed" not in r.stdout:
        raise AssertionError("could not install the helper into the test profile: " + (r.stdout + r.stderr)[-200:])
    saved = open(NOTE).read() if os.path.exists(NOTE) else None
    last = subprocess.run(["defaults", "read", "ai.codehatch.app", "lastEditorApp"], capture_output=True, text=True).stdout.strip()
    def link(path, **q):
        import urllib.parse
        subprocess.run(["/usr/bin/open", "-g", "vscode://codehatch.codehatch-helper/%s?%s" % (path, urllib.parse.urlencode(q))])
    def note_for(folder):
        return next((n for n in window_notes().values() if n.get("folders") == [folder]), None)
    def go(pid, cwd):
        r = subprocess.run([APP, "--go", str(pid), cwd], capture_output=True, text=True, timeout=60)
        return r.stdout.strip()
    try:
        for folder in (a, b):
            subprocess.run(base + ["--new-window", folder], capture_output=True, timeout=60)
            wait("the window for %s and its helper" % os.path.basename(folder), lambda: note_for(folder) and note().get("folder") == folder, timeout=60)
            # A terminal in that window (resumed in the window's project, as codehatch does): its shell is the "session".
            link("resume", tool="claude", id=str(uuid.uuid4()), cwd=folder)
            wait("a terminal in the window for " + os.path.basename(folder), lambda: (note_for(folder) or {}).get("shells"), timeout=30)
        shell_a, shell_b = note_for(a)["shells"][0], note_for(b)["shells"][0]
        before = set(window_notes())
        time.sleep(1)

        # B is in front. A session in A, started in a subfolder of A's project.
        eq(go(shell_a, sub), "window " + a, "a session started in a subfolder: its own window, found by its terminal")
        wait("A's terminal in front", lambda: note().get("pid") == shell_a and note().get("folder") == a, timeout=20)

        # A session in B, started in a folder no window has open (as in a home folder).
        eq(go(shell_b, os.path.expanduser("~")), "window " + b, "a session started outside any project: its own window")
        wait("B's terminal in front", lambda: note().get("pid") == shell_b and note().get("folder") == b, timeout=20)

        # Back to A, with a folder that does not exist at all.
        eq(go(shell_a, "/nonexistent/folder"), "window " + a, "a session whose folder is gone: still its own window")
        wait("A's terminal in front again", lambda: note().get("pid") == shell_a, timeout=20)

        # A window still running an older helper notes nothing: codehatch falls back to the session's own folder, which
        # brings back the right window when the session was started at the top of its project, as it did before.
        for name, n in window_notes().items():
            if n.get("folders") == [a]:
                os.remove(os.path.join(WINDOWS, name))
        eq(go(shell_a, a), "folder " + a, "a window with no note: found by the session's own folder")
        wait("A's terminal in front, with no note", lambda: note().get("pid") == shell_a and note().get("folder") == a, timeout=20)

        # A window with no folder open, holding the session's terminal (VS Code opened on its own, claude started in its
        # terminal in the home folder): there is no folder to open, so codehatch must not open one, which would make a
        # new window. Stood in for by noting A's window as having no folder, under a live process's name.
        for name, n in window_notes().items():
            if n.get("folders") == [a]:
                os.remove(os.path.join(WINDOWS, name))
        host = sb.sleeper()
        import json as _json
        with open(os.path.join(WINDOWS, "%d.json" % host), "w") as f:
            _json.dump({"folders": [], "shells": [shell_a], "app": "Visual Studio Code"}, f)
        eq(go(shell_a, os.path.expanduser("~")), "window with no folder", "a window with no folder: nothing is opened")
        os.remove(os.path.join(WINDOWS, "%d.json" % host))

        time.sleep(3)   # a new window would have noted itself by now
        eq(sorted(set(window_notes()) - before), [], "no new editor window was opened")
    finally:
        subprocess.run(["pkill", "-f", "user-data-dir " + data], capture_output=True)
        for _ in range(30):
            if subprocess.run(["pgrep", "-f", data], capture_output=True).returncode != 0:
                break
            time.sleep(0.5)
        if saved is not None:
            open(NOTE, "w").write(saved)
        if last:
            subprocess.run(["defaults", "write", "ai.codehatch.app", "lastEditorApp", last])


def test_app_editor_reopen_once(sb):
    """Reopening a closed session in an editor whose project window is not open yet: the window opens, a terminal in
    that project resumes the session, and the link to the helper is sent exactly once, so the editor asks at most once
    (before "Don't ask again" is ticked it asks about every link). Real VS Code, throwaway profile."""
    if not os.path.exists(CODE):
        raise AssertionError("VS Code is not installed")
    running = lambda: subprocess.run(["pgrep", "-f", "^/Applications/Visual Studio Code.app/Contents/MacOS/"], capture_output=True).returncode == 0
    for _ in range(40):
        if not running():
            break
        time.sleep(0.5)
    if running():
        raise AssertionError("VS Code is already open. Quit it first: the test needs to be the only copy running, so its links reach the test windows.")
    import glob, json, uuid
    vsix = sorted(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "editor-helper", "codehatch-helper-*.vsix")))
    repo = os.path.realpath(sb.repo("codehatch-test-reopen"))
    data, exts = sb.path("vscode-data"), sb.path("vscode-extensions")
    os.makedirs(os.path.join(data, "User"))
    with open(os.path.join(data, "User", "settings.json"), "w") as f:
        json.dump({"security.workspace.trust.enabled": False, "extensions.confirmedUriHandlerExtensionIds": ["codehatch.codehatch-helper"],
                   "update.mode": "none", "telemetry.telemetryLevel": "off", "workbench.startupEditor": "none", "window.restoreWindows": "none"}, f)
    base = [CODE, "--user-data-dir", data, "--extensions-dir", exts]
    r = subprocess.run(base + ["--install-extension", vsix[-1]], capture_output=True, text=True, timeout=120)
    if "successfully installed" not in r.stdout:
        raise AssertionError("could not install the helper into the test profile: " + (r.stdout + r.stderr)[-200:])
    saved = open(NOTE).read() if os.path.exists(NOTE) else None
    last = subprocess.run(["defaults", "read", "ai.codehatch.app", "lastEditorApp"], capture_output=True, text=True).stdout.strip()
    log = os.path.join(os.path.expanduser("~"), "Library", "Logs", "codehatch.log")
    try:
        before = set(window_notes())
        subprocess.run(base + ["--new-window"], capture_output=True, timeout=60)   # VS Code open, but not on this project
        wait("the empty test window and its helper", lambda: set(window_notes()) - before, timeout=60)
        mark = os.path.getsize(log) if os.path.exists(log) else 0
        sid = str(uuid.uuid4())
        r = subprocess.run([APP, "-reopenIn", "vscode", "--reopen", sid, repo], capture_output=True, text=True, timeout=90)
        eq(r.stdout.strip(), "editor Visual Studio Code", "it reopens in the chosen editor")
        win = wait("the project's window, with one terminal", lambda: next((n for n in window_notes().values() if n.get("folders") == [repo] and n.get("shells")), None), timeout=30)
        eq(len(win["shells"]), 1, "exactly one terminal was opened to resume it")
        cwd = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(win["shells"][0]), "-d", "cwd", "-Fn"], capture_output=True, text=True).stdout
        if repo not in cwd:
            raise AssertionError("the resuming terminal is not in the session's folder")
        with open(log, "rb") as f:
            f.seek(mark)
            sent = [l for l in f.read().decode("utf8", "replace").splitlines() if "resume: open vscode://codehatch.codehatch-helper/resume" in l]
        eq(len(sent), 1, "the link to the helper was sent once")
    finally:
        subprocess.run(["pkill", "-f", "user-data-dir " + data], capture_output=True)
        for _ in range(30):
            if subprocess.run(["pgrep", "-f", data], capture_output=True).returncode != 0:
                break
            time.sleep(0.5)
        if saved is not None:
            open(NOTE, "w").write(saved)
        if last:
            subprocess.run(["defaults", "write", "ai.codehatch.app", "lastEditorApp", last])


TABS = {
    # Two more tabs in the window just opened, each running the given command; returns their devices.
    "terminal": 'on run argv\n tell application "Terminal"\n activate\n tell application "System Events" to keystroke "t" using command down\n delay 0.8\n do script (item 1 of argv) in selected tab of front window\n delay 0.6\n return tty of selected tab of front window\n end tell\nend run',
    "iterm": 'on run argv\n tell application id "com.googlecode.iterm2"\n tell current window to set t to (create tab with default profile)\n tell current session of t to write text (item 1 of argv)\n delay 0.8\n return tty of current session of t\n end tell\nend run',
}


def test_app_iterm_tabs(sb):
    """iTerm2, several tabs in one window: going to a session selects its tab, not just its window."""
    if not os.path.isdir("/Applications/iTerm.app"):
        raise AssertionError("iTerm2 is not installed")
    sc = SCRIPTS["iterm"]
    repo = sb.repo("codehatch-test-tabs")
    before = set(osa(IDS["iterm"]).split())
    ttys = []
    try:
        first = osa(sc["open"], "cd '%s' && sleep 921" % repo); ttys.append(first)
        second = osa(TABS["iterm"], "cd '%s' && sleep 922" % repo); ttys.append(second)
        third = osa(TABS["iterm"], "cd '%s' && sleep 923" % repo); ttys.append(third)
        eq(osa(sc["front"]), third, "the last tab opened is the one in front")
        pid = wait("the first tab's process", lambda: (on_tty(first, "sleep") or [None])[0])
        out = subprocess.run([APP, "--focus-terminal", str(pid)], capture_output=True, text=True, timeout=60).stdout.strip()
        eq(out, "ok iterm " + first, "what the app reported")
        eq(osa(sc["front"]), first, "the first tab, in the same window, is now the one in front")
        mid = wait("the second tab's process", lambda: (on_tty(second, "sleep") or [None])[0])
        subprocess.run([APP, "--focus-terminal", str(mid)], capture_output=True, text=True, timeout=60)
        eq(osa(sc["front"]), second, "and then the middle tab")
    finally:
        for tty in ttys:
            for p in on_tty(tty):
                try:
                    os.kill(p, 9)
                except OSError:
                    pass
        time.sleep(0.5)
        for wid in set(osa(IDS["iterm"]).split()) - before:
            try:
                osa(CLOSE_ID["iterm"], wid)
            except AssertionError:
                pass


def test_app_terminal_real_claude(sb):
    """Terminal with a real Claude Code session: codehatch lists it, and going to it lands on its window."""
    import shutil, json as _json
    if not shutil.which("claude"):
        raise AssertionError("claude is not installed")
    sc = SCRIPTS["terminal"]
    repo = sb.repo("codehatch-test-real-claude")
    before = set(osa(IDS["terminal"]).split())
    ttys = []
    try:
        # Started with the env markers of any surrounding Claude session removed, as a person would start it.
        tty = osa(sc["open"], "cd '%s' && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT claude" % repo); ttys.append(tty)
        time.sleep(6)
        # A folder Claude Code has not seen asks whether to trust it; choose "Yes" (down, then return).
        osa('on run argv\n tell application "Terminal"\n repeat with w in windows\n try\n if (tty of selected tab of w) is (item 1 of argv) then do script (ASCII character 27) & "[B" in selected tab of w\n end try\n end repeat\n end tell\nend run', tty)
        def listed():
            for s in run.dump(sb, real_home=True)["sessions"]:
                if s["tool"] == "claude" and os.path.realpath(s["cwd"]) == os.path.realpath(repo):
                    return s
        import run
        s = wait("the real session to be listed", listed, timeout=45)
        other = osa(sc["open"], "cd '%s' && sleep 931" % repo); ttys.append(other)
        eq(osa(sc["front"]), other, "another window is in front")
        out = subprocess.run([APP, "--focus-terminal", str(s["pid"])], capture_output=True, text=True, timeout=60).stdout.strip()
        eq(out, "ok terminal " + tty, "what the app reported")
        eq(osa(sc["front"]), tty, "the real session's window is now in front")
    finally:
        for t in ttys:
            for p in on_tty(t):
                try:
                    os.kill(p, 9)
                except OSError:
                    pass
        time.sleep(0.6)
        for wid in set(osa(IDS["terminal"]).split()) - before:
            try:
                osa(CLOSE_ID["terminal"], wid)
            except AssertionError:
                pass


TESTS = [test_app_terminal, test_app_iterm, test_app_iterm_tabs, test_app_terminal_real_claude, test_app_vscode, test_app_editor_windows, test_app_editor_reopen_once]
