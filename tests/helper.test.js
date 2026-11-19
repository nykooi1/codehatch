// Tests for the editor helper's own logic, with a stand-in for the editor. Run by tests/run.py, or: node tests/helper.test.js
// The stand-in records what the helper asks the editor to do, so nothing here opens a window.
const Module = require("module"), path = require("path"), fs = require("fs"), os = require("os"), assert = require("assert");

const home = fs.mkdtempSync(path.join(os.tmpdir(), "codehatch-helper-test-"));   // a pretend home folder
os.homedir = () => home;

const shown = [], created = [], commands = [];
let handler = null;
const terminal = (pid) => ({ processId: Promise.resolve(pid), show: () => { shown.push(pid); editor.window.activeTerminal = terminals.find((t) => t.pid === pid).t; } });
const terminals = [101, 202, 303].map((pid) => ({ pid, t: terminal(pid) }));
const editor = {
  window: {
    state: { focused: true },
    activeTerminal: terminals[0].t,
    get terminals() { return terminals.map((x) => x.t); },
    registerUriHandler: (h) => { handler = h; return { dispose() {} }; },
    onDidChangeActiveTerminal: () => ({ dispose() {} }),
    onDidChangeWindowState: () => ({ dispose() {} }),
    createTerminal: (opts) => { const made = { opts, sent: [], show() {}, sendText(text) { made.sent.push(text); } }; created.push(made); return made; },
  },
  workspace: { workspaceFolders: [{ uri: { fsPath: "/Projects/storefront" } }] },
  commands: { executeCommand: async (name) => { commands.push(name); } },
};
const load = Module._load;
Module._load = (request, ...rest) => (request === "vscode" ? editor : load(request, ...rest));
require("../editor-helper/extension.js").activate({ subscriptions: [] });

const send = (p, query) => handler.handleUri({ path: p, query });
const note = () => JSON.parse(fs.readFileSync(path.join(home, ".codehatch", "active-terminal.json"), "utf8"));
const id = "11111111-2222-3333-4444-555555555555";

(async () => {
  await new Promise((r) => setTimeout(r, 20));
  assert.deepStrictEqual([note().pid, note().folder], [101, "/Projects/storefront"], "on start it notes the terminal in front and the folder");

  await send("/focus", "pids=999,202,5");
  assert.deepStrictEqual(shown, [202], "focus shows the terminal whose process is in the list, and only that one");
  assert.strictEqual(note().pid, 202, "and notes it as the one in front");
  await send("/focus", "pids=777");
  assert.deepStrictEqual(shown, [202], "focus does nothing when no terminal matches");

  await send("/resume", `tool=claude&id=${id}&cwd=${encodeURIComponent("/Projects/storefront")}`);
  assert.strictEqual(created.length, 1, "resume opens one new terminal");
  assert.strictEqual(created[0].opts.cwd, "/Projects/storefront", "in the session's folder");
  assert.deepStrictEqual(created[0].sent, [`claude --resume ${id}`], "and runs exactly the resume command");
  await send("/resume", `tool=claude&id=${id}&cwd=${encodeURIComponent("/Projects/storefront")}`);
  assert.strictEqual(created.length, 1, "a repeat of the same link within a minute opens nothing more");

  const other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  await send("/resume", `tool=codex&id=${other}&cwd=${encodeURIComponent("/Projects/storefront/packages/web")}`);
  assert.deepStrictEqual(created[1].sent, [`codex resume ${other}`], "Codex sessions resume with Codex's command, and a subfolder of the project is accepted");

  const before = created.length;
  await send("/resume", `tool=claude&id=${encodeURIComponent("x; rm -rf ~")}&cwd=${encodeURIComponent("/Projects/storefront")}`);
  await send("/resume", `tool=bash&id=${id.replace("1", "9")}&cwd=${encodeURIComponent("/Projects/storefront")}`);
  await send("/resume", `tool=claude&id=${id.replace("1", "8")}&cwd=${encodeURIComponent("/Projects/other-project")}`);
  await send("/resume", `tool=claude&id=${id.replace("1", "7")}&cwd=${encodeURIComponent("/Projects/storefront-evil")}`);
  assert.strictEqual(created.length, before, "a bad id, an unknown tool, another project, or a folder that only starts with the same letters: all refused");

  await send("/panel", `cwd=${encodeURIComponent("/Projects/storefront")}`);
  assert.deepStrictEqual(commands, ["claude-vscode.focus"], "panel sessions bring the Claude Code panel forward");
  await send("/panel", `cwd=${encodeURIComponent("/Projects/other-project")}`);
  assert.strictEqual(commands.length, 1, "but not in a window that has a different project open");

  await send("/something-else", "");
  fs.rmSync(home, { recursive: true, force: true });
  console.log("helper ok");
})().catch((e) => { fs.rmSync(home, { recursive: true, force: true }); console.error("helper FAIL: " + e.message); process.exit(1); });
