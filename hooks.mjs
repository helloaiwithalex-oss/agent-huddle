#!/usr/bin/env node
// Adds or removes Agent Huddle's hooks in ~/.claude/settings.json without touching anything else in it.
//   node hooks.mjs add "<node binary>"   (install.sh)
//   node hooks.mjs remove                (uninstall.sh)
// Our entries are the ones whose command runs .agent-huddle/hook.js, so running it twice never duplicates them.
// Before the first install, a copy of your original file is saved as settings.json.agent-huddle-backup
// (never overwritten by a reinstall); uninstall deletes it once the hooks are out.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const FILE = process.env.CLAUDE_SETTINGS || path.join(os.homedir(), ".claude", "settings.json");
const MARK = ".agent-huddle/hook.js";
// Every event the widget listens to. PermissionRequest waits for your click, so it gets 10 minutes.
const EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                "Notification", "Stop", "SubagentStart", "SubagentStop", "PermissionRequest"];

const [mode, nodeBin = "node"] = process.argv.slice(2);
if (mode !== "add" && mode !== "remove") {
  console.error('usage: node hooks.mjs add "<node binary>" | remove');
  process.exit(2);
}

let settings = {};
let raw = "";
if (fs.existsSync(FILE)) {
  raw = fs.readFileSync(FILE, "utf8");
  try { settings = raw.trim() ? JSON.parse(raw) : {}; }
  catch (e) {
    console.error(`error: ${FILE} isn't valid JSON (${e.message}). Fix it first; nothing was changed.`);
    process.exit(1);
  }
}
if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
  console.error(`error: ${FILE} isn't a JSON object; nothing was changed.`);
  process.exit(1);
}

const isOurs = (h) => typeof h?.command === "string" && h.command.includes(MARK);
const hooks = settings.hooks && typeof settings.hooks === "object" ? settings.hooks : {};

// Take out any earlier Agent Huddle entries (keeps the file clean on reinstall, and is all "remove" does).
let removed = 0;
for (const [event, groups] of Object.entries(hooks)) {
  if (!Array.isArray(groups)) continue;
  const kept = [];
  for (const g of groups) {
    if (!Array.isArray(g?.hooks)) { kept.push(g); continue; }
    const inner = g.hooks.filter((h) => !isOurs(h));
    removed += g.hooks.length - inner.length;
    if (inner.length) kept.push({ ...g, hooks: inner });
  }
  if (kept.length) hooks[event] = kept; else delete hooks[event];
}

if (mode === "add") {
  const q = (s) => `"${s.replace(/(["\\$`])/g, "\\$1")}"`;
  const command = `${q(nodeBin)} "$HOME/${MARK}"`;
  for (const event of EVENTS) {
    (hooks[event] ||= []).push({
      matcher: "",
      hooks: [{ type: "command", command, timeout: event === "PermissionRequest" ? 600 : 5 }],
    });
  }
}

if (Object.keys(hooks).length) settings.hooks = hooks; else delete settings.hooks;

fs.mkdirSync(path.dirname(FILE), { recursive: true });
const BACKUP = `${FILE}.agent-huddle-backup`;
// Back up only a file that has none of our hooks yet, so the backup always holds your settings from before Agent Huddle.
if (mode === "add" && raw && removed === 0) fs.writeFileSync(BACKUP, raw);
const tmp = `${FILE}.agent-huddle-tmp`;
const fileMode = raw ? fs.statSync(FILE).mode & 0o777 : 0o600;  // keep the file's own permissions
fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + "\n", { mode: fileMode });
fs.chmodSync(tmp, fileMode);
fs.renameSync(tmp, FILE);
// After uninstall the backup is out of date (and restoring an old one with our hooks would point at a deleted hook.js).
if (mode === "remove") fs.rmSync(BACKUP, { force: true });
console.log(mode === "add"
  ? `added Agent Huddle hooks to ${FILE} (${EVENTS.length} events)`
  : `removed ${removed} Agent Huddle hook entr${removed === 1 ? "y" : "ies"} from ${FILE}`);
