#!/usr/bin/env python3
"""codehatch's automated tests.

    python3 tests/run.py            the fast tests: pretend sessions for Claude Code and Codex
    python3 tests/run.py --live     also start one real Claude Code and one real Codex session
    python3 tests/run.py --apps     also drive the real apps (Terminal, iTerm2, Cursor, VS Code); opens windows briefly
    python3 tests/run.py -k codex   only tests whose name contains "codex"

Everything the tests create lives in one sandbox folder, ~/.codehatch-tests/run-<time>-<pid>, which is
removed at the end. Pretend repos, a pretend home folder and pretend settings files are all inside it.

Safety, in order of importance:
  * Nothing outside the sandbox is ever deleted. There is exactly one function that deletes a folder
    (Sandbox.destroy) and it refuses unless the folder is a real directory, directly inside
    ~/.codehatch-tests, named run-..., and holds the marker file this script wrote when it made it.
  * The fast tests never read or write your real ~/.claude or ~/.codex. The app is pointed at the
    pretend home with CODEHATCH_HOME.
  * The only processes ever stopped are ones this script started itself.
Uses the Python standard library only.
"""
import json, os, shutil, signal, sqlite3, subprocess, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
APPDIR = os.path.dirname(HERE)
APP = os.path.join(APPDIR, ".build", "codehatch.app", "Contents", "MacOS", "codehatch")
HOOK = os.path.join(APPDIR, "hooks", "codehatch-hook.sh")
TESTS_ROOT = os.path.join(os.path.expanduser("~"), ".codehatch-tests")
MARKER = ".codehatch-test-sandbox"


class Sandbox:
    """One throwaway folder. Everything the tests make goes in here."""

    def __init__(self):
        os.makedirs(TESTS_ROOT, exist_ok=True)
        self.root = os.path.join(TESTS_ROOT, "run-%d-%d" % (int(time.time()), os.getpid()))
        os.mkdir(self.root)  # fails if it already exists: never reuse someone else's folder
        with open(os.path.join(self.root, MARKER), "w") as f:
            f.write("made by codehatch tests; safe to delete\n")
        self.home = self.path("home")
        self.pids = []
        os.makedirs(self.home)

    def path(self, *parts):
        p = os.path.realpath(os.path.join(self.root, *parts))
        if not (p == os.path.realpath(self.root) or p.startswith(os.path.realpath(self.root) + os.sep)):
            raise RuntimeError("refusing a path outside the sandbox: " + p)
        return p

    def repo(self, name):
        """A pretend repo: an empty folder with a git folder in it."""
        p = self.path("repos", name)
        os.makedirs(os.path.join(p, ".git"), exist_ok=True)
        return p

    def spawn(self, argv, **kw):
        p = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kw)
        self.pids.append(p.pid)
        return p

    def sleeper(self, cwd=None):
        """A process that does nothing, standing in for a running session."""
        return self.spawn(["/bin/sleep", "900"], cwd=cwd).pid

    def stop_all(self):
        for pid in self.pids:  # only ever processes started above
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        self.pids = []

    def destroy(self):
        """The only place a folder is deleted. Every condition must hold or nothing is touched."""
        root = self.root
        parent = os.path.realpath(TESTS_ROOT)
        real = os.path.realpath(root)
        ok = (
            os.path.isdir(root)
            and not os.path.islink(root)
            and os.path.dirname(real) == parent
            and os.path.basename(real).startswith("run-")
            and os.path.isfile(os.path.join(real, MARKER))
            and parent == os.path.join(os.path.realpath(os.path.expanduser("~")), ".codehatch-tests")
        )
        if not ok:
            print("  ! not deleting %s: it does not look like a sandbox this script made" % root)
            return False
        shutil.rmtree(real)
        return True


# ── laying out pretend sessions ──

def now_ms():
    return int(time.time() * 1000)


def escaped(cwd):
    return "".join(c if c.isalnum() else "-" for c in cwd)


def claude_session(sb, pid, cwd, status="idle", ago=60, sid=None, waiting=None, name=None, name_source="derived", entrypoint="cli", kind="interactive"):
    sid = sid or str(uuid.uuid4())
    d = os.path.join(sb.home, ".claude", "sessions")
    os.makedirs(d, exist_ok=True)
    at = now_ms() - int(ago * 1000)
    o = {"pid": pid, "sessionId": sid, "cwd": cwd, "status": status, "startedAt": at - 60000, "updatedAt": at, "statusUpdatedAt": at,
         "kind": kind, "entrypoint": entrypoint, "name": name or (os.path.basename(cwd) + "-ab"), "nameSource": name_source}
    if waiting:
        o["waitingFor"] = waiting
    with open(os.path.join(d, "%d.json" % pid), "w") as f:
        json.dump(o, f)
    return sid


def claude_history(sb, sid, cwd, lines):
    d = os.path.join(sb.home, ".claude", "projects", escaped(cwd))
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, sid + ".jsonl")
    with open(p, "w") as f:
        for o in lines:
            f.write(json.dumps(o, separators=(",", ":")) + "\n")
    return p


def user(text, cwd, branch="main", meta=False):
    o = {"type": "user", "cwd": cwd, "gitBranch": branch, "message": {"role": "user", "content": text}}
    if meta:
        o["isMeta"] = True
    return o


def title(text):
    return {"type": "ai-title", "aiTitle": text}


def recap(text):
    return {"type": "system", "subtype": "away_summary", "content": text}


def hook_event(sb, tool, sid, event, ago=0, cwd="", kind="", pid=0):
    d = os.path.join(sb.home, ".codehatch", "live")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "%s-%s.json" % (tool, sid)), "w") as f:
        json.dump({"tool": tool, "event": event, "pid": pid, "at": int(time.time() - ago), "session_id": sid, "cwd": cwd, "kind": kind}, f)


def codex_session(sb, cwd, title_text="Codex task", branch="main", working=False, preview=""):
    """A pretend Codex session: a process named codex holding its session log open, plus a row in Codex's database."""
    sid = str(uuid.uuid4())
    day = os.path.join(sb.home, ".codex", "sessions", "2026", "11", "17")
    os.makedirs(day, exist_ok=True)
    log = os.path.join(day, "rollout-2026-11-17T12-00-00-%s.jsonl" % sid)
    with open(log, "w") as f:
        f.write(json.dumps({"type": "session_meta", "payload": {"cwd": cwd}}) + "\n")
        f.write(json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n")
        if not working:
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete"}}) + "\n")
    db = os.path.join(sb.home, ".codex", "state_5.sqlite")
    con = sqlite3.connect(db)
    con.execute("create table if not exists threads (id text primary key, title text, name text, cwd text, git_branch text, preview text, first_user_message text)")
    con.execute("insert into threads values (?,?,?,?,?,?,?)", (sid, title_text, "", cwd, branch, preview, "first thing asked"))
    con.commit(); con.close()
    binary = sb.path("bin", "codex")
    if not os.path.exists(binary):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        shutil.copy("/bin/sleep", binary)  # a do-nothing program whose name is "codex"
        # macOS refuses to run a copied system program until it is signed again
        subprocess.run(["codesign", "--force", "-s", "-", binary], capture_output=True)
    fd = os.open(log, os.O_RDONLY)
    p = sb.spawn([binary, "900"], cwd=cwd, pass_fds=[fd])
    os.close(fd)
    return sid, p.pid, log


def codex_session_new_style(sb, cwd, asked="do the thing", working=False):
    """Newer Codex: the process holds no log. The log is written by a background service, after the process started."""
    binary = sb.path("bin", "codex")
    if not os.path.exists(binary):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        shutil.copy("/bin/sleep", binary)
        subprocess.run(["codesign", "--force", "-s", "-", binary], capture_output=True)
    p = sb.spawn([binary, "900"], cwd=cwd)
    time.sleep(1.1)
    sid = str(uuid.uuid4())
    day = os.path.join(sb.home, ".codex", "sessions", "2026", "11", "17")
    os.makedirs(day, exist_ok=True)
    log = os.path.join(day, "rollout-2026-11-17T12-00-00-%s.jsonl" % sid)
    with open(log, "w") as f:
        f.write(json.dumps({"type": "session_meta", "payload": {"cwd": cwd}}, separators=(",", ":")) + "\n")
        f.write(json.dumps({"type": "event_msg", "payload": {"type": "user_message", "message": asked}}, separators=(",", ":")) + "\n")
        f.write(json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}, separators=(",", ":")) + "\n")
        if not working:
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete"}}, separators=(",", ":")) + "\n")
    return sid, p.pid, log


def dump(sb, *args, pids=None, real_home=False):
    env = dict(os.environ)
    if not real_home:
        env["CODEHATCH_HOME"] = sb.home
        env["CODEHATCH_TEST_PIDS"] = ",".join(str(p) for p in (pids or []))
    r = subprocess.run([APP, "--dump", *args], capture_output=True, text=True, env=env, timeout=60)
    line = [l for l in r.stdout.splitlines() if l.startswith("{")]
    if not line:
        raise AssertionError("the app printed no dump. stderr: " + r.stderr[-300:])
    return json.loads(line[-1])


def by_id(d, sid):
    for s in d["sessions"]:
        if s["id"] == sid:
            return s
    raise AssertionError("session %s is missing from the list" % sid[:8])


def eq(got, want, what):
    if got != want:
        raise AssertionError("%s: expected %r, got %r" % (what, want, got))


# ── the fast tests ──

def test_claude_states(sb):
    """Working, idle, waiting on you and never-used Claude Code sessions each show the right state."""
    r = sb.repo("storefront")
    busy = claude_session(sb, sb.sleeper(), r, "busy", ago=20)
    idle = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    wait = claude_session(sb, sb.sleeper(), r, "waiting", ago=5, waiting="permission prompt")
    new = claude_session(sb, sb.sleeper(), r, "idle", ago=30)
    for sid, t in ((busy, "Speed up search"), (idle, "Old task"), (wait, "Checkout bug")):
        claude_history(sb, sid, r, [user("do the thing", r, "feature/x"), title(t)])
    d = dump(sb)
    eq(by_id(d, busy)["state"], "working", "busy session")
    eq(by_id(d, idle)["state"], "idle", "long-idle session")
    eq(by_id(d, wait)["state"], "needs you", "waiting session")
    eq(by_id(d, wait)["waitingFor"], "permission prompt", "what it waits for")
    eq(by_id(d, new)["state"], "unused", "never-used session")
    eq(by_id(d, new)["empty"], True, "never-used session is marked empty")
    eq(by_id(d, busy)["repo"], "storefront", "repo name")


def test_claude_just_finished(sb):
    """A session that stopped a moment ago, and that you have not been to, shows as finished."""
    r = sb.repo("storefront")
    sid = claude_session(sb, sb.sleeper(), r, "idle", ago=30)
    claude_history(sb, sid, r, [user("ship it", r), title("Banner")])
    eq(by_id(dump(sb), sid)["state"], "finished", "recently stopped session")


def test_claude_details(sb):
    """Title, branch, last message and recap are read from the session's history."""
    r = sb.repo("api-server")
    sid = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    claude_history(sb, sid, r, [
        user("first thing", r, "main"), title("Rate limit the export endpoint"), recap("Limits are in. Next: enterprise."),
        user("<system-note>ignore me</system-note>", r, "feature/export-rate-limit"),
        user("skipped because meta", r, "feature/export-rate-limit", meta=True),
        user("100 a minute per account is fine", r, "feature/export-rate-limit"),
        user("This session is being continued from a previous conversation that ran out of context.", r, "feature/export-rate-limit"),
    ])
    s = by_id(dump(sb), sid)
    eq(s["title"], "Rate limit the export endpoint", "title")
    eq(s["branch"], "feature/export-rate-limit", "branch is the most recent one recorded")
    eq(s["lastAsked"], "100 a minute per account is fine", "last message skips notes, meta lines and the continuation note")
    eq(s["recap"], "Limits are in. Next: enterprise.", "recap")


def said(text, tools=False):
    parts = ([{"type": "tool_use", "name": "Bash", "input": {}}] if tools else []) + ([{"type": "text", "text": text}] if text else [])
    return {"type": "assistant", "message": {"role": "assistant", "content": parts}}


def test_last_message_either_side(sb):
    """Each row shows the last thing said by either side: the agent's reply if it came last, otherwise yours."""
    r = sb.repo("storefront")
    replied = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    claude_history(sb, replied, r, [user("is the cache working?", r), title("Cache"), said("", tools=True), said("**Yes.** Hit rate is `94%` after the change.\n\n- More detail below."), said("", tools=True)])
    waiting = claude_session(sb, sb.sleeper(), r, "busy", ago=10)
    claude_history(sb, waiting, r, [user("first", r), title("Banner"), said("Done with the first part."), user("now make it end at midnight", r)])
    d = dump(sb)
    eq(by_id(d, replied)["lastMessage"], "Yes. Hit rate is 94% after the change. More detail below.", "the agent spoke last: its lines joined, formatting marks removed, tool calls skipped")
    eq(by_id(d, replied)["lastAsked"], "is the cache working?", "your last message is still kept")
    eq(by_id(d, waiting)["lastMessage"], "You: now make it end at midnight", "you spoke last")


def test_claude_title_fallbacks(sb):
    """No title yet: the first prompt is used. A name you gave with /rename beats both."""
    r = sb.repo("docs-site")
    a = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    claude_history(sb, a, r, [user("rewrite the getting started guide", r)])
    b = claude_session(sb, sb.sleeper(), r, "idle", ago=4000, name="My own name", name_source="user")
    claude_history(sb, b, r, [user("anything", r), title("Automatic title")])
    d = dump(sb)
    eq(by_id(d, a)["title"], "rewrite the getting started guide", "untitled session uses its first prompt")
    eq(by_id(d, b)["title"], "My own name", "a /rename name wins")


def test_claude_dead_session_ignored(sb):
    """A status file whose process is gone is not shown."""
    r = sb.repo("storefront")
    p = sb.spawn(["/bin/sleep", "900"])
    sid = claude_session(sb, p.pid, r, "busy")
    claude_history(sb, sid, r, [user("x", r), title("Gone")])
    p.kill(); p.wait()
    if any(s["id"] == sid for s in dump(sb)["sessions"]):
        raise AssertionError("a session whose process has ended is still listed")


def test_order_recent_and_by_repo(sb):
    """Most recent first as one list; or grouped by repo in alphabetical order; never-used sessions last."""
    a, b = sb.repo("zebra"), sb.repo("alpha")
    z1 = claude_session(sb, sb.sleeper(), a, "idle", ago=4000)
    z2 = claude_session(sb, sb.sleeper(), a, "busy", ago=10)
    a1 = claude_session(sb, sb.sleeper(), b, "idle", ago=5000)
    unused = claude_session(sb, sb.sleeper(), b, "idle", ago=1)
    for sid, r in ((z1, a), (z2, a), (a1, b)):
        claude_history(sb, sid, r, [user("x", r), title("t")])
    eq(dump(sb, "-notchOrder", "recent")["order"], [z2, z1, a1, unused], "most recent first, unused last")
    eq(dump(sb, "-notchOrder", "repo")["order"], [a1, unused, z2, z1], "alphabetical repos, recent first inside each")


def test_hidden_repos_and_labels(sb):
    """Repos you chose to hide are left out; a name you gave in codehatch replaces the title."""
    keep, hide = sb.repo("storefront"), sb.repo("client-site")
    k = claude_session(sb, sb.sleeper(), keep, "idle", ago=4000)
    h = claude_session(sb, sb.sleeper(), hide, "idle", ago=4000)
    for sid, r in ((k, keep), (h, hide)):
        claude_history(sb, sid, r, [user("x", r), title("Original")])
    d = dump(sb, "-hiddenRepos", "Client-Site, other", "-labels", '{"%s" = "Renamed here";}' % k)
    eq([s["id"] for s in d["sessions"]], [k], "only the visible repo's session is listed")
    eq(by_id(d, k)["title"], "Renamed here", "codehatch's own name")


def test_recently_closed(sb):
    """A conversation with no open session is offered for reopening, unless its folder is gone."""
    r = sb.repo("storefront")
    open_sid = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    claude_history(sb, open_sid, r, [user("x", r), title("Still open")])
    closed = str(uuid.uuid4())
    claude_history(sb, closed, r, [user("ship it", r, "fix/cart-badge"), title("Fix the cart badge")])
    gone = str(uuid.uuid4())
    claude_history(sb, gone, sb.path("repos", "deleted-repo"), [user("x", sb.path("repos", "deleted-repo")), title("Folder is gone")])
    d = dump(sb)
    eq([s["id"] for s in d["recent"]], [closed], "exactly the closed conversation whose folder exists")
    eq(d["recent"][0]["state"], "closed", "its state")
    eq(d["recent"][0]["branch"], "fix/cart-badge", "its branch")
    eq(dump(sb, "-showRecent", "NO")["recent"], [], "nothing when the setting is off")


def test_renamed_closed_session(sb):
    """A session renamed with /rename keeps that name once closed, even after Claude Code writes a newer title."""
    r = sb.repo("storefront")
    renamed = str(uuid.uuid4())
    claude_history(sb, renamed, r, [user("fix the login", r), title("Fix login redirect"),
                                    {"type": "custom-title", "customTitle": "Login, take two"}, title("A later title")])
    plain = str(uuid.uuid4())
    claude_history(sb, plain, r, [user("add tests", r), title("Add unit tests")])
    closed = {s["id"]: s for s in dump(sb)["recent"]}
    eq(closed[renamed]["title"], "Login, take two", "the name given with /rename")
    eq(closed[plain]["title"], "Add unit tests", "Claude Code's own title when never renamed")


def test_background_sessions_hidden(sb):
    """Sessions Claude Code runs in the background (a fork) are left out, running or ended, even when hooks speak."""
    r = sb.repo("storefront")
    normal = claude_session(sb, sb.sleeper(), r, "idle", ago=30)
    claude_history(sb, normal, r, [user("x", r), title("Normal session")])
    pid = sb.sleeper()
    fork = claude_session(sb, pid, r, "idle", ago=30, kind="bg")
    claude_history(sb, fork, r, [dict(user("x", r), sessionKind="bg"), title("Forked session")])
    hook_event(sb, "claude", fork, "UserPromptSubmit", ago=2, cwd=r, pid=pid)
    ended = str(uuid.uuid4())
    claude_history(sb, ended, r, [dict(user("x", r), sessionKind="bg"), title("Ended fork")])
    talks = str(uuid.uuid4())   # a normal conversation that only mentions the marker, as text
    claude_history(sb, talks, r, [user('it says "sessionKind":"bg" in the file', r), title("Talks about forks")])
    d = dump(sb, "-liveUpdates", "YES")
    ids = [s["id"] for s in d["sessions"]] + [s["id"] for s in d["recent"]]
    eq(normal in ids and talks in ids, True, "normal sessions are listed")
    eq(fork in ids, False, "a running background session is left out, even after a hook event")
    eq(ended in ids, False, "an ended background session is left out of recently closed")


def test_hooks_claude(sb):
    """With hooks on, the newest word about a session wins, whether it came from a hook or the status file."""
    r = sb.repo("storefront")
    asks = claude_session(sb, sb.sleeper(), r, "busy", ago=30)          # hook says it now needs permission
    escaped_turn = claude_session(sb, sb.sleeper(), r, "idle", ago=5)   # stopped with Escape: no hook fired, status file is newer
    answer = claude_session(sb, sb.sleeper(), r, "busy", ago=30)
    for sid in (asks, escaped_turn, answer):
        claude_history(sb, sid, r, [user("x", r), title("t")])
    hook_event(sb, "claude", asks, "PermissionRequest", ago=2, cwd=r)
    hook_event(sb, "claude", escaped_turn, "UserPromptSubmit", ago=60, cwd=r)
    hook_event(sb, "claude", answer, "Notification", ago=2, cwd=r, kind="elicitation_dialog")
    pid = sb.sleeper()
    only_hook = str(uuid.uuid4())                                       # no status file at all
    claude_history(sb, only_hook, r, [user("x", r), title("Known from hooks only")])
    hook_event(sb, "claude", only_hook, "UserPromptSubmit", ago=3, cwd=r, pid=pid)
    d = dump(sb, "-liveUpdates", "YES")
    eq(by_id(d, asks)["state"], "needs you", "permission request reported by hook")
    eq(by_id(d, escaped_turn)["state"], "finished", "newer status file beats an older hook event")
    eq(by_id(d, answer)["state"], "needs you", "a question for you reported by hook")
    eq(by_id(d, only_hook)["state"], "working", "session known only from hooks")
    eq(by_id(d, only_hook)["title"], "Known from hooks only", "its title still comes from its history")
    off = dump(sb, "-liveUpdates", "NO")
    eq(by_id(off, asks)["state"], "working", "hooks are ignored when the setting is off")


def test_codex_states(sb):
    """Codex sessions: working until the task completes, with title and branch from Codex's own records."""
    r = sb.repo("ios-app")
    w_sid, w_pid, _ = codex_session(sb, r, "Push arrives twice", "bugfix/duplicate-push", working=True)
    i_sid, i_pid, _ = codex_session(sb, r, "Onboarding redesign", "feature/onboarding-v2", working=False, preview="Three of four screens done.")
    d = dump(sb, pids=[w_pid, i_pid])
    w, i = by_id(d, "codex-" + w_sid), by_id(d, "codex-" + i_sid)
    eq(w["tool"], "codex", "tool"); eq(w["state"], "working", "task started and not complete")
    eq(w["title"], "Push arrives twice", "title"); eq(w["branch"], "bugfix/duplicate-push", "branch"); eq(w["repo"], "ios-app", "repo")
    eq(i["status"], "idle", "task complete"); eq(i["recap"], "Three of four screens done.", "preview used as the recap")


def test_codex_new_style(sb):
    """Newer Codex holds no log open: the session is matched to its log by folder, and old logs are not mistaken for it."""
    r, other = sb.repo("ios-app"), sb.repo("api-server")
    day = os.path.join(sb.home, ".codex", "sessions", "2026", "11", "16")
    os.makedirs(day)
    stale = os.path.join(day, "rollout-2026-11-16T09-00-00-%s.jsonl" % uuid.uuid4())
    with open(stale, "w") as f:  # an earlier, closed session in the same folder
        f.write(json.dumps({"type": "session_meta", "payload": {"cwd": r}}, separators=(",", ":")) + "\n")
    os.utime(stale, (time.time() - 3600, time.time() - 3600))
    w_sid, w_pid, _ = codex_session_new_style(sb, r, "check the tokens", working=True)
    i_sid, i_pid, _ = codex_session_new_style(sb, other, "rate limit it", working=False)
    fresh = sb.spawn([sb.path("bin", "codex"), "900"], cwd=sb.repo("docs-site")).pid   # opened, nothing asked yet
    d = dump(sb, pids=[w_pid, i_pid, fresh])
    w, i = by_id(d, "codex-" + w_sid), by_id(d, "codex-" + i_sid)
    eq(w["state"], "working", "task started and not complete"); eq(w["repo"], "ios-app", "repo"); eq(w["title"], "check the tokens", "named by its first message")
    eq(i["status"], "idle", "task complete"); eq(i["repo"], "api-server", "repo")
    eq(by_id(d, "codex-pid-%d" % fresh)["state"], "unused", "a session nothing has been asked in")
    eq(len(d["sessions"]), 3, "three sessions, and the stale log made none")


def test_hooks_codex(sb):
    """With hooks on, a Codex session that asks for approval shows as needing you, which nothing else can tell."""
    r = sb.repo("ios-app")
    sid, pid, _ = codex_session(sb, r, "Needs approval", working=True)
    eq(by_id(dump(sb, pids=[pid]), "codex-" + sid)["state"], "working", "without hooks it only looks busy")
    hook_event(sb, "codex", sid, "PermissionRequest", ago=1, cwd=r)
    eq(by_id(dump(sb, "-liveUpdates", "YES", pids=[pid]), "codex-" + sid)["state"], "needs you", "approval request reported by hook")
    hook_event(sb, "codex", sid, "Interrupt", ago=0, cwd=r)
    eq(by_id(dump(sb, "-liveUpdates", "YES", pids=[pid]), "codex-" + sid)["status"], "idle", "an interrupted turn is no longer working")


def test_mixed_tools_summary(sb):
    """Claude Code and Codex sessions appear together and the summary counts both."""
    r = sb.repo("storefront")
    c = claude_session(sb, sb.sleeper(), r, "busy", ago=10)
    claude_history(sb, c, r, [user("x", r), title("Claude task")])
    sid, pid, _ = codex_session(sb, r, "Codex task", working=True)
    d = dump(sb, pids=[pid])
    eq(sorted(s["tool"] for s in d["sessions"]), ["claude", "codex"], "both tools listed")
    if "2 working" not in d["summary"]:
        raise AssertionError("summary should count both as working: " + d["summary"])


def test_hook_script(sb):
    """The hook records the event, keeps none of the prompt, prints nothing and always exits 0."""
    home = sb.path("hook-home")
    env = dict(os.environ, HOME=home)
    payload = json.dumps({"session_id": "abc-123", "cwd": "/Users/me/my repo", "notification_type": "permission_prompt", "prompt": "SECRET words", "tool_input": {"command": "rm -rf /"}})
    r = subprocess.run(["/bin/sh", HOOK, "claude", "Notification"], input=payload, capture_output=True, text=True, env=env)
    eq(r.returncode, 0, "exit code"); eq(r.stdout, "", "prints nothing"); eq(r.stderr, "", "no errors")
    f = os.path.join(home, ".codehatch", "live", "claude-abc-123.json")
    o = json.load(open(f))
    eq((o["tool"], o["event"], o["session_id"], o["cwd"], o["kind"]), ("claude", "Notification", "abc-123", "/Users/me/my repo", "permission_prompt"), "what it recorded")
    raw = open(f).read()
    if "SECRET" in raw or "rm -rf" in raw:
        raise AssertionError("the hook wrote prompt or tool details to disk")
    bad = subprocess.run(["/bin/sh", HOOK, "claude", "Stop"], input=json.dumps({"session_id": "../../evil"}), capture_output=True, text=True, env=env)
    eq(bad.returncode, 0, "exit code for a bad id")
    eq(sorted(os.listdir(os.path.join(home, ".codehatch", "live"))), ["claude-abc-123.json"], "a session id that is not a plain id writes nothing")
    empty = subprocess.run(["/bin/sh", HOOK, "codex", "Stop"], input="", capture_output=True, text=True, env=env)
    eq((empty.returncode, empty.stdout), (0, ""), "no input at all is still harmless")


def test_hooks_install_and_remove(sb):
    """Turning hooks on adds only codehatch's entries; turning them off puts both files back as they were."""
    home = sb.path("settings-home")
    os.makedirs(os.path.join(home, ".claude")); os.makedirs(os.path.join(home, ".codex"))
    mine = {"model": "x", "permissions": {"allow": ["Bash(ls)"]}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-hook"}]}]}}
    cs = os.path.join(home, ".claude", "settings.json")
    json.dump(mine, open(cs, "w"))
    run = lambda *a: subprocess.run([APP, "--hooks-selftest", home, *a], capture_output=True, text=True, timeout=60)
    out = run("--keep").stdout
    if "install: ok" not in out:
        raise AssertionError("install did not report ok: " + out)
    run("--keep")  # a second time must not add a second copy
    after = json.load(open(cs))
    eq({k: v for k, v in after.items() if k != "hooks"}, {k: v for k, v in mine.items() if k != "hooks"}, "other settings untouched")
    stop = [h["command"] for g in after["hooks"]["Stop"] for h in g["hooks"]]
    eq(stop.count("/usr/local/bin/my-own-hook"), 1, "your own hook is kept")
    eq(len([c for c in stop if "codehatch-hook.sh" in c]), 1, "exactly one codehatch entry after installing twice")
    for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "SessionEnd"):
        if event not in after["hooks"]:
            raise AssertionError("missing Claude Code hook for " + event)
    codex = json.load(open(os.path.join(home, ".codex", "hooks.json")))
    for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"):
        if event not in codex["hooks"]:
            raise AssertionError("missing Codex hook for " + event)
    if not os.access(os.path.join(home, ".codehatch", "codehatch-hook.sh"), os.X_OK):
        raise AssertionError("the hook script was not put in place")
    if not os.path.exists(cs + ".before-codehatch"):
        raise AssertionError("no backup of the settings file was made")
    run()  # install then remove
    eq(json.load(open(cs)), mine, "settings identical to the original after removal")
    if os.path.exists(os.path.join(home, ".codex", "hooks.json")):
        raise AssertionError("Codex hooks file should be gone when it held only codehatch's hooks")


def test_editor_helper(sb):
    """The editor helper (Cursor, VS Code): focus the right tab, resume in the right folder, refuse anything else."""
    r = subprocess.run(["node", os.path.join(HERE, "helper.test.js")], capture_output=True, text=True, timeout=60)
    if r.returncode != 0 or "helper ok" not in r.stdout:
        raise AssertionError((r.stderr or r.stdout).strip()[-300:])


def spread(sb):
    """Six sessions over three repos, one or two in each state, for the tests of what the interface would show."""
    a, b, c = sb.repo("storefront"), sb.repo("ios-app"), sb.repo("api-server")
    ids = {
        "needs": claude_session(sb, sb.sleeper(), a, "waiting", ago=5, waiting="permission prompt"),
        "needs2": claude_session(sb, sb.sleeper(), c, "waiting", ago=50, waiting="permission prompt"),
        "working": claude_session(sb, sb.sleeper(), a, "busy", ago=20),
        "finished": claude_session(sb, sb.sleeper(), b, "idle", ago=40),
        "idle": claude_session(sb, sb.sleeper(), b, "idle", ago=4000),
        "unused": claude_session(sb, sb.sleeper(), c, "idle", ago=30),
    }
    names = {"needs": "Checkout fails for saved cards", "needs2": "Flaky login test", "working": "Speed up search", "finished": "Banner", "idle": "Onboarding"}
    for k, r in (("needs", a), ("needs2", c), ("working", a), ("finished", b), ("idle", b)):
        claude_history(sb, ids[k], r, [user("do the thing", r, "feature/x"), title(names[k])])
    return ids


def test_dashboard_groups(sb):
    """The dashboard groups by state in order of urgency, or by repo; the Active filter leaves out what has not been touched in a day."""
    ids = spread(sb)
    stale_repo = sb.repo("ios-app")
    stale = claude_session(sb, sb.sleeper(), stale_repo, "idle", ago=200000)   # idle for more than two days
    claude_history(sb, stale, stale_repo, [user("x", stale_repo), title("Stale")])
    groups = lambda *a: [(g["name"], g["items"], g["unused"]) for g in dump(sb, *a)["dashboard"]]
    by_state = groups("-widgetGroup", "state", "-widgetFilter", "all")
    eq([g[0] for g in by_state], ["Needs you", "Finished", "Working", "Idle, used today", "Idle, older", "Never used"], "state groups, most urgent first")
    eq(by_state[0][1], [ids["needs"], ids["needs2"]], "both sessions that need you, the most recent first")
    eq(by_state[-1][2], [ids["unused"]], "the never-used session sits apart")
    by_repo = groups("-widgetGroup", "repo", "-widgetFilter", "all")
    eq(sorted(g[0] for g in by_repo), ["api-server", "ios-app", "storefront"], "one group per repo")
    store = [g for g in by_repo if g[0] == "storefront"][0]
    eq(sorted(store[1]), sorted([ids["needs"], ids["working"]]), "storefront's sessions")
    api = [g for g in by_repo if g[0] == "api-server"][0]
    eq((api[1], api[2]), ([ids["needs2"]], [ids["unused"]]), "a repo's never-used session is kept apart from its used ones")
    active = [i for g in groups("-widgetGroup", "state", "-widgetFilter", "active") for i in g[1] + g[2]]
    eq(sorted(active), sorted([ids["needs"], ids["needs2"], ids["working"], ids["finished"], ids["idle"]]), "Active keeps anything used in the last day, and leaves out the stale and the never-used")


def test_dashboard_recently_closed(sb):
    """Recently closed sessions come last on the dashboard, and are folded by repo, the most recent repo first."""
    live, old1, old2 = sb.repo("storefront"), sb.repo("docs-site"), sb.repo("api-server")
    sid = claude_session(sb, sb.sleeper(), live, "busy", ago=10)
    claude_history(sb, sid, live, [user("x", live), title("Live one")])
    for n, (r, age) in enumerate(((old1, 3), (old2, 1), (old1, 2))):
        p = claude_history(sb, "00000000-0000-4000-8000-00000000000%d" % n, r, [user("earlier work", r), title("Closed %d" % n)])
        t = time.time() - age * 3600
        os.utime(p, (t, t))
    d = dump(sb, "-widgetGroup", "state", "-widgetFilter", "all")
    eq(d["dashboard"][-1]["name"], "Recently closed · click to resume", "the last group")
    eq(len(d["dashboard"][-1]["items"]), 3, "all three closed sessions are in it")
    eq(d["closedRepos"], ["api-server", "docs-site"], "one fold per repo, the repo closed most recently first")
    eq([g["name"] for g in dump(sb, "-widgetGroup", "state", "-widgetFilter", "active")["dashboard"]], ["Working"], "the Active filter hides closed sessions")


def test_beside_the_notch(sb):
    """Beside the notch: the most urgent session's name cut at a word, a count of the others like it, and the other two ways of showing it."""
    ids = spread(sb)
    d = dump(sb)
    eq(d["spotlight"], ids["needs"], "the most recent session that needs you is the one shown")
    eq(d["beside"]["name"], {"text": "Checkout fails…", "count": "+1"}, "name: cut at a word within 16 characters, with the other one counted")
    eq(d["beside"]["state"], {"text": "needs you", "count": "+1"}, "state: the word, and the count")
    eq(d["beside"]["orb"], {"text": "", "count": "2"}, "orb alone: no words, and the total")
    # The counts at the top of the panel, from fullest to shortest, for when they would not fit beside the camera.
    eq(d["summaries"], ["2 need you · 1 finished · 1 working · 6 open", "2 need you · 1 finished · 1 working", "2 need you · 1 working", "2 need you"], "the counts, shortening without ever dropping what needs you")
    eq(d["summaries"][0], d["summary"], "the fullest is the usual line")


def test_beside_the_notch_quiet(sb):
    """With nothing working, waiting or just finished, nothing shows beside the notch; a short name is not cut."""
    r = sb.repo("storefront")
    sid = claude_session(sb, sb.sleeper(), r, "idle", ago=4000)
    claude_history(sb, sid, r, [user("x", r), title("Old task")])
    d = dump(sb)
    eq((d["spotlight"], d["beside"]), ("", {}), "nothing to show")
    busy = claude_session(sb, sb.sleeper(), r, "busy", ago=5)
    claude_history(sb, busy, r, [user("x", r), title("Fix cart badge")])
    eq(dump(sb)["beside"]["name"], {"text": "Fix cart badge", "count": ""}, "a short name whole, and no count when it is the only one")


def test_defaults_and_menu(sb):
    """What a new user gets: cards grouped by state, nothing forced on top, hooks off until asked; and a way to quit."""
    d = dump(sb)
    want = {"widgetLayout": "cards", "widgetGroup": "state", "widgetFilter": "all", "widgetOnTop": False, "liveUpdates": False, "beaconShows": "orb",
            "showBeacon": True, "showMenuIcon": True, "openOnHover": True, "showRecent": True, "recentDays": 14, "notchOrder": "recent", "windowLook": "system", "confirmClose": True, "didSetup": False}
    eq({k: d["defaults"].get(k) for k in want}, want, "the defaults")
    menu = {m["title"]: m["key"] for m in d["menu"]}
    eq(menu.get("Quit codehatch"), "q", "Command-Q quits")
    eq(menu.get("Settings…"), ",", "Command-comma opens settings")
    eq((menu.get("Copy"), menu.get("Paste"), menu.get("Select All")), ("c", "v", "a"), "copy, paste and select all work in text fields")


def test_hook_never_waits(sb):
    """A session being shut down may never finish sending its input. The hook must carry on within a couple of seconds, and still record the event."""
    home = sb.path("hook-home")
    env = dict(os.environ, HOME=home)
    p = subprocess.Popen(["/bin/bash", HOOK, "claude", "SessionEnd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    sb.pids.append(p.pid)
    p.stdin.write(b'{"session_id":"slow-1","cwd":"/x/y"}\n'); p.stdin.flush()   # and then never close it
    start = time.time()
    try:
        p.wait(timeout=4)
    except subprocess.TimeoutExpired:
        p.kill()
        raise AssertionError("the hook was still waiting for input after 4 seconds")
    eq(p.returncode, 0, "exit code")
    if time.time() - start > 3:
        raise AssertionError("the hook took more than 3 seconds")
    eq(json.load(open(os.path.join(home, ".codehatch", "live", "claude-slow-1.json")))["event"], "SessionEnd", "the event was still recorded")
    silent = subprocess.Popen(["/bin/bash", HOOK, "codex", "Stop"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    sb.pids.append(silent.pid)
    try:
        silent.wait(timeout=4)   # nothing sent at all, and never closed
    except subprocess.TimeoutExpired:
        silent.kill()
        raise AssertionError("the hook waited forever when nothing was sent")


def test_everything_draws(sb):
    """Each part of the interface draws, at its proper size, in the light look and the dark: light is light, dark is dark, and neither is blank."""
    # "panel-desktop" is the notch panel on a Mac with no notch: a desktop Mac or an external display.
    sizes = {"dashboard": (1180, 640), "panel": (640, 470), "panel-desktop": (640, 470), "settings": (520, 560), "setup": (470, 480)}
    for what, size in sizes.items():
        seen = {}
        for look in ("light", "dark") if what in ("dashboard", "setup", "settings") else ("dark",):
            out = sb.path("%s-%s.png" % (what, look))
            r = subprocess.run([APP, "--render", what, look, out], capture_output=True, text=True, timeout=60)
            line = [l for l in r.stdout.splitlines() if l.startswith("{")]
            if not line or not os.path.exists(out) or os.path.getsize(out) < 2000:
                raise AssertionError("%s in the %s look did not draw: %s" % (what, look, (r.stdout + r.stderr)[-200:]))
            o = json.loads(line[-1]); seen[look] = o
            if size and (o["width"], o["height"]) not in ((size[0], size[1]), (size[0] * 2, size[1] * 2)):
                raise AssertionError("%s drew at %sx%s, not %sx%s" % (what, o["width"], o["height"], size[0], size[1]))
            if o["shades"] < 6:
                raise AssertionError("%s in the %s look is nearly blank (%d shades)" % (what, look, o["shades"]))
        if "light" in seen and seen["light"]["lightness"] < 0.75:
            raise AssertionError("%s in the light look is not light (%.2f)" % (what, seen["light"]["lightness"]))
        if seen["dark"]["lightness"] > 0.45:   # the panels are part see-through; drawn with nothing behind, their blur comes out mid-grey
            raise AssertionError("%s in the dark look is not dark (%.2f)" % (what, seen["dark"]["lightness"]))


def test_drawing_leaves_settings_alone(sb):
    """Drawing a picture for the tests uses sample sessions, and must not leave the sample-sessions setting switched on for the real app."""
    read = lambda: subprocess.run(["defaults", "read", "ai.codehatch.app", "demoMode"], capture_output=True, text=True).stdout.strip()
    before = read()
    subprocess.run([APP, "--render", "panel", "dark", sb.path("p.png")], capture_output=True, text=True, timeout=60)
    eq(read(), before, "the saved sample-sessions setting, before and after drawing")


def test_automation_denial_is_recognised(sb):
    """When macOS refuses to let codehatch control Terminal or iTerm2, the app recognises it (and tells the person how to fix it)."""
    check = lambda text: subprocess.run([APP, "--check-denial", text], capture_output=True, text=True, timeout=30).stdout.strip()
    eq(check("execution error: Not authorized to send Apple events to Terminal. (-1743)"), "denied", "the refusal")
    eq(check("execution error: Can't get window 1 of application \"Terminal\". (-1728)"), "other", "an ordinary error")
    eq(check(""), "other", "no error at all")


def test_setup_installs_both(sb):
    """The welcome window's button: hooks go into Claude Code's and Codex's settings, and the helper into the editor, here all inside the sandbox."""
    home = sb.path("setup-home")
    os.makedirs(os.path.join(home, ".claude")); os.makedirs(os.path.join(home, ".codex"))
    json.dump({"model": "x"}, open(os.path.join(home, ".claude", "settings.json"), "w"))
    editors = dump(sb)["helperEditors"]
    pick = "vscode" if "vscode" in editors else (editors[0] if editors else "")
    ext = sb.path("editor-extensions")
    env = dict(os.environ, CODEHATCH_HELPER_DIR=ext)   # the helper goes here, not into your editor
    r = subprocess.run([APP, "--setup-selftest", home, pick or "none"], capture_output=True, text=True, timeout=180, env=env)
    line = [l for l in r.stdout.splitlines() if l.startswith("[")]
    if not line:
        raise AssertionError("setup printed nothing: " + (r.stdout + r.stderr)[-300:])
    done = {x["what"]: x["problem"] for x in json.loads(line[-1])}
    eq(done.get("Live updates"), "", "hooks installed without a problem")
    after = json.load(open(os.path.join(home, ".claude", "settings.json")))
    eq(after.get("model"), "x", "your own settings are kept")
    if "codehatch-hook.sh" not in json.dumps(after.get("hooks", {})) or not os.path.exists(os.path.join(home, ".codex", "hooks.json")):
        raise AssertionError("the hooks are not in both tools' settings")
    if not pick:
        print("          (note: no editor built on VS Code is installed, so the helper part was skipped)")
        return
    helper = [k for k in done if k.startswith("Helper for ")]
    eq([done[k] for k in helper], [""], "the helper installed without a problem")
    if not [f for f in os.listdir(ext) if f.lower().startswith("codehatch.codehatch-helper-")]:
        raise AssertionError("the helper is not in the editor's extensions folder")
    if os.path.exists(os.path.join(ext, "extensions.json")):
        listed = open(os.path.join(ext, "extensions.json")).read()
        if "codehatch.codehatch-helper" not in listed:
            raise AssertionError("the editor does not list the helper as installed")


def test_close_session(sb):
    """Closing ends the session and the shell it was started from, and leaves any other parent alone."""
    shell = sb.spawn(["/bin/zsh", "-c", "sleep 911 & wait"])
    time.sleep(0.6)
    child = int(subprocess.run(["pgrep", "-P", str(shell.pid)], capture_output=True, text=True).stdout.split()[0])
    sb.pids.append(child)
    subprocess.run([APP, "--close-and-exit", str(child)], timeout=30)
    time.sleep(0.3)
    if alive(child) or shell.poll() is None:
        raise AssertionError("the session or its shell is still running after close")
    parent = sb.spawn([sys.executable, "-c", "import subprocess,time; p=subprocess.Popen(['/bin/sleep','912']); print(p.pid, flush=True); time.sleep(900)"], )
    time.sleep(0.8)
    kid = int(subprocess.run(["pgrep", "-P", str(parent.pid)], capture_output=True, text=True).stdout.split()[0])
    sb.pids.append(kid)
    subprocess.run([APP, "--close-and-exit", str(kid)], timeout=30)
    time.sleep(0.3)
    if alive(kid):
        raise AssertionError("the session is still running after close")
    if parent.poll() is not None:
        raise AssertionError("a parent that is not a shell was stopped too")


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # a finished child that has not been collected still answers; ask ps for its state
    st = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(st) and not st.startswith("Z")


FAST = [test_claude_states, test_claude_just_finished, test_claude_details, test_last_message_either_side, test_claude_title_fallbacks, test_claude_dead_session_ignored,
        test_order_recent_and_by_repo, test_hidden_repos_and_labels, test_recently_closed, test_renamed_closed_session, test_background_sessions_hidden, test_hooks_claude, test_codex_states,
        test_codex_new_style, test_hooks_codex, test_mixed_tools_summary, test_hook_script, test_hook_never_waits, test_hooks_install_and_remove, test_editor_helper, test_close_session,
        test_dashboard_groups, test_dashboard_recently_closed, test_beside_the_notch, test_beside_the_notch_quiet, test_defaults_and_menu,
        test_everything_draws, test_drawing_leaves_settings_alone, test_automation_denial_is_recognised, test_setup_installs_both]


def main():
    args = sys.argv[1:]
    only = args[args.index("-k") + 1] if "-k" in args else ""
    tests = list(FAST)
    if "--live" in args:
        import live
        tests += live.TESTS
    if "--apps" in args:
        import apps
        tests += apps.TESTS
    tests = [t for t in tests if only in t.__name__]
    if not os.access(APP, os.X_OK):
        print("The app is not built. Run scripts/run.sh first."); return 2
    passed, failed = 0, []
    for t in tests:
        sb = Sandbox()  # a fresh, empty sandbox for every test
        try:
            t(sb)
            passed += 1
            print("  ok    %s" % t.__name__)
        except Exception as e:  # noqa: BLE001 - report every kind of failure the same way
            failed.append(t.__name__)
            print("  FAIL  %s\n          %s\n          %s" % (t.__name__, (t.__doc__ or "").strip(), e))
        finally:
            sb.stop_all()
            sb.destroy()
    left = [d for d in os.listdir(TESTS_ROOT) if d.startswith("run-")] if os.path.isdir(TESTS_ROOT) else []
    print("\n%d passed, %d failed%s" % (passed, len(failed), "" if not left else "  (left behind: %s)" % ", ".join(left)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
