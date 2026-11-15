// Agent Huddle helper: the widget can't click things inside VS Code, so it drops small request files in
// ~/.agent-huddle/commands/ and this extension carries them out:
//   {action: "focus" | "close", claude_pid, claude_ppid, session_id, cwd, panel}
// - Terminal sessions (`claude` typed in a terminal): found by process id, shown or closed.
// - Chat-panel sessions: opened by session id through the Claude Code extension's own command, then closed if asked.
// Only the window that owns the terminal, or has the session's folder open, acts. It never types anything.
"use strict";
const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");

const COMMANDS = path.join(os.homedir(), ".agent-huddle", "commands");
const SESSION_ID = /^[0-9a-f-]{36}$/i;

/// Is this session's folder open in this window?
function ownsFolder(cwd) {
  if (!cwd) return false;
  return (vscode.workspace.workspaceFolders || []).some((f) => {
    const root = f.uri.fsPath;
    return cwd === root || cwd.startsWith(root + path.sep);
  });
}

/// Take the file so no other window acts on it too (only one rename wins).
function claim(file) {
  const claimed = file.replace(/\.json$/, `.claimed-${process.pid}`);
  try { fs.renameSync(file, claimed); } catch { return false; }
  try { fs.unlinkSync(claimed); } catch {}
  return true;
}

let running = false;
async function runCommands() {
  if (running) return;
  running = true;
  try {
    let names;
    try { names = fs.readdirSync(COMMANDS).filter((n) => n.endsWith(".json")).sort(); } catch { return; }
    if (!names.length) return;
    const terms = await Promise.all(vscode.window.terminals.map(async (t) => [t, await t.processId]));
    for (const name of names) {
      const file = path.join(COMMANDS, name);
      let cmd;
      try { cmd = JSON.parse(fs.readFileSync(file, "utf8")); } catch { continue; }
      if (cmd.action !== "focus" && cmd.action !== "close") continue;

      // terminal session in this window: the claude process itself, or the shell it was typed into
      const hit = terms.find(([, pid]) => pid && (pid === cmd.claude_pid || pid === cmd.claude_ppid));
      if (hit) {
        if (!claim(file)) continue;
        if (cmd.action === "close") hit[0].dispose(); else hit[0].show();
        continue;
      }

      // chat-panel session: open it by id (reveals its tab, or reopens it), close it if asked
      if (cmd.panel && SESSION_ID.test(cmd.session_id || "") && ownsFolder(cmd.cwd)) {
        if (!claim(file)) continue;
        try { await vscode.commands.executeCommand("claude-vscode.primaryEditor.open", cmd.session_id); }
        catch { continue; }  // Claude Code extension missing or too old
        if (cmd.action === "close") {
          await new Promise((r) => setTimeout(r, 400));
          const tab = vscode.window.tabGroups.activeTabGroup.activeTab;
          // only ever close a Claude chat tab
          if (tab && tab.input instanceof vscode.TabInputWebview && /claudeVSCodePanel/.test(tab.input.viewType)) {
            await vscode.window.tabGroups.close(tab);
          }
        }
      }
    }
  } finally {
    running = false;
  }
}

function activate(context) {
  fs.mkdirSync(COMMANDS, { recursive: true });
  let timer = null;
  const watcher = fs.watch(COMMANDS, () => { clearTimeout(timer); timer = setTimeout(runCommands, 100); });
  const poll = setInterval(runCommands, 5000);  // in case a file event is missed
  context.subscriptions.push({ dispose: () => { watcher.close(); clearInterval(poll); clearTimeout(timer); } });
  runCommands();  // a click made while VS Code was starting
}

module.exports = { activate };
