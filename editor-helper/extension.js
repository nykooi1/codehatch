// The whole helper.
// 1. When the portal sends "focus?pids=...", show the terminal whose shell is one of those processes.
// 2. Whenever this window is in front or its active terminal changes, note which terminal that is in
//    ~/.codehatch/active-terminal.json, so the portal can mark the session you are in.
// 3. When the portal sends "resume?...", reopen a closed session in a new terminal (see resume below).
// 4. When the portal sends "panel?...", bring the Claude Code extension's chat panel forward (see panel below).
// 5. Keep a note of this window, in ~/.codehatch/windows: the folders it has open and the shells of its terminals, so
//    the portal can bring this exact window forward (by its own folder) instead of opening a session's folder anew.
const vscode = require("vscode");
const fs = require("fs"), os = require("os"), path = require("path");
const dir = path.join(os.homedir(), ".codehatch"), file = path.join(dir, "active-terminal.json");

async function report() {
  try {
    if (!vscode.window.state.focused) return;
    const terminal = vscode.window.activeTerminal;
    const pid = terminal ? await terminal.processId : null;
    const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0] ? vscode.workspace.workspaceFolders[0].uri.fsPath : null;
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ pid: pid || null, folder, at: Date.now() }));
  } catch (_) {}
}

// 3. When the portal sends "resume?tool=...&id=...&cwd=...", open a new terminal in this window and resume that
//    session in it. The command is built here from a checked session id, never taken from the link, and it only
//    runs if this window has that folder open, so a link can do nothing except reopen one of your own sessions.
const resumed = new Map();
function resume(q) {
  const tool = q.get("tool"), id = q.get("id") || "", cwd = q.get("cwd") || "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return;
  if (tool !== "claude" && tool !== "codex") return;
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  if (!folders.some((f) => cwd === f || cwd.startsWith(f + path.sep))) return;   // not this window's project
  if (Date.now() - (resumed.get(id) || 0) < 60000) return;                       // the portal sends the link more than once
  resumed.set(id, Date.now());
  const terminal = vscode.window.createTerminal({ cwd });
  terminal.show(false);
  terminal.sendText(tool === "codex" ? `codex resume ${id}` : `claude --resume ${id}`, true);
}

// 4. When the portal sends "panel?cwd=...", bring the Claude Code extension's chat panel forward. That is where a
//    session lives when it was started from the extension and so has no terminal tab. Only in the window that has
//    that folder open. The extension offers no way to pick one conversation, so with several open it shows the last.
async function panel(q) {
  const cwd = q.get("cwd") || "";
  const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
  if (!folders.some((f) => cwd === f || cwd.startsWith(f + path.sep))) return;
  try { await vscode.commands.executeCommand("claude-vscode.focus"); }
  catch (_) { try { await vscode.commands.executeCommand("claude-vscode.editor.openLast"); } catch (_) {} }
}

// 5. This window's note: one file per window, named after this window's extension host, removed when it closes.
const windows = path.join(dir, "windows"), note = path.join(windows, process.pid + ".json");
async function noteWindow() {
  try {
    const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
    const shells = (await Promise.all(vscode.window.terminals.map((t) => t.processId))).filter(Boolean);
    fs.mkdirSync(windows, { recursive: true });
    fs.writeFileSync(note, JSON.stringify({ folders, shells, app: vscode.env.appName, at: Date.now() }));
  } catch (_) {}
}

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        if (uri.path === "/resume") return resume(new URLSearchParams(uri.query));
        if (uri.path === "/panel") return panel(new URLSearchParams(uri.query));
        if (uri.path !== "/focus") return;
        const pids = (new URLSearchParams(uri.query).get("pids") || "").split(",").map(Number).filter(Boolean);
        for (const terminal of vscode.window.terminals) {
          const pid = await terminal.processId;
          if (pid && pids.includes(pid)) { terminal.show(false); report(); return; }
        }
      },
    }),
    vscode.window.onDidChangeActiveTerminal(report),
    vscode.window.onDidChangeWindowState(report),
    vscode.window.onDidOpenTerminal(noteWindow),
    vscode.window.onDidCloseTerminal(noteWindow),
    vscode.workspace.onDidChangeWorkspaceFolders(noteWindow)
  );
  report();
  noteWindow();
}

module.exports = { activate, deactivate() { try { fs.unlinkSync(note); } catch (_) {} } };
