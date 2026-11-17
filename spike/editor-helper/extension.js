// The whole helper.
// 1. When the portal sends "focus?pids=...", show the terminal whose shell is one of those processes.
// 2. Whenever this window is in front or its active terminal changes, note which terminal that is in
//    ~/.fathomed/active-terminal.json, so the portal can mark the session you are in.
const vscode = require("vscode");
const fs = require("fs"), os = require("os"), path = require("path");
const dir = path.join(os.homedir(), ".fathomed"), file = path.join(dir, "active-terminal.json");

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

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        if (uri.path !== "/focus") return;
        const pids = (new URLSearchParams(uri.query).get("pids") || "").split(",").map(Number).filter(Boolean);
        for (const terminal of vscode.window.terminals) {
          const pid = await terminal.processId;
          if (pid && pids.includes(pid)) { terminal.show(false); report(); return; }
        }
      },
    }),
    vscode.window.onDidChangeActiveTerminal(report),
    vscode.window.onDidChangeWindowState(report)
  );
  report();
}

module.exports = { activate, deactivate() {} };
