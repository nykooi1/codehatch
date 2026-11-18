"""Tests that start real Claude Code and Codex sessions. Run with: python3 tests/run.py --live

Each one starts the real tool in a terminal of its own (not a window: an invisible one this script holds), inside a
pretend repo in the sandbox, sends one tiny prompt, and checks what codehatch shows as the session works and stops.
They use a little of your Claude and Codex usage, and take about a minute each.

They read your real ~/.claude and ~/.codex, since that is where the real tools write, but they change nothing in
them. The sessions are closed again at the end, and the only folder removed is the sandbox.
"""
import json, os, pty, select, shutil, subprocess, threading, time

from run import APP, alive, dump, eq

HOME = os.path.expanduser("~")
PROMPT = "Reply with exactly the word ok and nothing else."


class Terminal:
    """A shell in a terminal that only this script can see."""

    def __init__(self, sb, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # the child: become a plain shell with no startup files, in the pretend repo
            os.chdir(cwd)
            os.environ["TERM"] = "xterm-256color"
            # If these tests are themselves started from inside a Claude Code or Codex session, the new session would
            # inherit markers that make it behave as a child of that one (it saves no history, for one). Drop them so
            # it starts exactly as it would from an ordinary terminal.
            for k in [k for k in os.environ if k.startswith(("CLAUDE", "CODEX", "ANTHROPIC_"))]:
                del os.environ[k]
            os.execv("/bin/zsh", ["zsh", "-f"])
        sb.pids.append(self.pid)
        import fcntl, struct, termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))  # a normal-sized window
        self.seen = b""
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        try:
            while True:
                r, _, _ = select.select([self.fd], [], [], 0.5)
                if r:
                    data = os.read(self.fd, 65536)
                    if not data:
                        return
                    self.seen = (self.seen + data)[-200000:]
                    # A real terminal answers the questions a full-screen program asks as it starts. Codex waits
                    # for these answers before it draws anything, so give the ones a plain terminal would.
                    if b"\x1b[6n" in data:
                        os.write(self.fd, b"\x1b[1;1R")      # where is the cursor? top left
                    if b"\x1b[c" in data or b"\x1b[0c" in data:
                        os.write(self.fd, b"\x1b[?1;2c")     # what kind of terminal? a basic one
                    if b"\x1b[?u" in data:
                        os.write(self.fd, b"\x1b[?0u")       # extended keyboard mode? not supported
        except OSError:
            return

    def type(self, text):
        os.write(self.fd, text.encode())

    def children(self):
        return [int(x) for x in subprocess.run(["pgrep", "-P", str(self.pid)], capture_output=True, text=True).stdout.split()]


def wait_for(what, check, timeout, every=1.0):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = check()
        if last:
            return last
        time.sleep(every)
    raise AssertionError("timed out after %ds waiting for %s" % (timeout, what))


def mine(sb, tool, cwd):
    """The session codehatch lists for this pretend repo, or None."""
    for s in dump(sb, real_home=True)["sessions"]:
        if s["tool"] == tool and os.path.realpath(s["cwd"]) == os.path.realpath(cwd):
            return s
    return None


def test_live_claude(sb):
    """A real Claude Code session: appears when opened, works on a prompt, finishes, and closes with its shell."""
    if not shutil.which("claude"):
        raise AssertionError("claude is not installed")
    repo = sb.repo("codehatch-test-claude")
    term = Terminal(sb, repo)
    time.sleep(0.5)
    term.type("claude\r")
    # A folder Claude Code has not seen asks "is this a project you trust?", with "No, exit" picked. Wait for the
    # question, move down to "Yes, I trust this folder", and confirm. The folder is the empty pretend repo.
    wait_for("Claude Code to start", lambda: b"trust" in term.seen.replace(b" ", b"") or mine(sb, "claude", repo), 30)
    if not mine(sb, "claude", repo):
        time.sleep(0.5)
        term.type("\x1b[B")
        time.sleep(0.3)
        term.type("\r")
    s = wait_for("the session to appear in codehatch", lambda: mine(sb, "claude", repo), 45)
    eq(s["state"], "unused", "a session nothing has been asked in")
    sb.pids.append(s["pid"])
    time.sleep(2)
    term.type(PROMPT)
    time.sleep(0.5)
    term.type("\r")
    seen = set()

    def finished():
        now = mine(sb, "claude", repo)
        if now:
            seen.add(now["status"])
        return now if now and now["status"] == "idle" and now["lastAsked"] else None

    done = wait_for("the session to work and then stop", finished, 150, every=0.7)
    eq(done["lastAsked"], PROMPT, "the last message")
    eq(done["state"], "finished", "state after the turn ends")
    if "busy" not in seen:
        print("          (note: the turn was too quick to catch it in the working state)")
    hooks_on = "codehatch-hook.sh" in open(os.path.join(HOME, ".claude", "settings.json")).read()
    if hooks_on:
        f = os.path.join(HOME, ".codehatch", "live", "claude-%s.json" % done["id"])
        ev = wait_for("the hook to have recorded this session", lambda: os.path.exists(f) and json.load(open(f)), 10)
        if ev["event"] not in ("Stop", "Notification", "PostToolUse", "UserPromptSubmit"):
            raise AssertionError("unexpected last hook event: " + ev["event"])
    else:
        print("          (note: hooks are not installed, so the hook part was skipped)")
    subprocess.run([APP, "--close-and-exit", str(done["pid"])], timeout=30)
    time.sleep(0.5)
    if alive(done["pid"]):
        raise AssertionError("the session is still running after close")
    if alive(term.pid):
        raise AssertionError("the shell it was started from is still running after close")
    if mine(sb, "claude", repo):
        raise AssertionError("the closed session is still listed as open")


def test_live_codex(sb):
    """A real Codex session: appears when opened, works on a prompt, and stops."""
    if not shutil.which("codex"):
        raise AssertionError("codex is not installed")
    repo = sb.repo("codehatch-test-codex")
    term = Terminal(sb, repo)
    time.sleep(0.5)
    term.type("codex\r")
    time.sleep(7)
    term.type("\r")  # accept "allow Codex to work in this folder?" if it asks
    s = wait_for("the session to appear in codehatch", lambda: mine(sb, "codex", repo), 45)
    sb.pids.append(s["pid"])
    time.sleep(2)
    term.type(PROMPT)
    time.sleep(0.5)
    term.type("\r")
    seen = set()

    def finished():
        now = mine(sb, "codex", repo)
        if now:
            seen.add(now["status"])
        return now if now and not now["empty"] and now["status"] == "idle" else None

    done = wait_for("the session to work and then stop", finished, 150, every=0.7)
    if "busy" not in seen:
        print("          (note: the turn was too quick to catch it in the working state)")
    eq(done["lastAsked"], PROMPT, "the last message")
    if "ok" not in done["lastMessage"].lower():
        raise AssertionError("the last message shown is not Codex's reply: %r" % done["lastMessage"])
    if not done["title"] or done["title"] == "New session":
        raise AssertionError("the session has no title after a prompt: %r" % done["title"])
    subprocess.run([APP, "--close-and-exit", str(done["pid"])], timeout=30)
    time.sleep(0.5)
    if alive(done["pid"]):
        raise AssertionError("the session is still running after close")


TESTS = [test_live_claude, test_live_codex]
