#!/usr/bin/env node
// Agent Huddle hook: forwards every Claude Code hook event to the floating widget (app/main.swift).
// install.sh copies it to ~/.agent-huddle/hook.js and registers it in ~/.claude/settings.json, so every
// session on this Mac reports. If the widget isn't running, it does nothing and exits 0.
//
// PermissionRequest is the one event that waits: the widget holds the request open until you click
// Allow or Deny, and this script prints that decision. No answer (or widget closed) = print nothing, so
// Claude falls back to its normal prompt in VS Code.
"use strict";
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const HOME_DIR = process.env.AGENT_HUDDLE_HOME || path.join(os.homedir(), ".agent-huddle");
const SERVER_JSON = path.join(HOME_DIR, "server.json");
const WAIT_MS = 9.5 * 60 * 1000;  // just under the 600s PermissionRequest hook timeout install.sh sets

// Walk up the parent processes to the `claude` binary. Terminal tabs run the CLI (~/.local/share/claude/...),
// the VS Code chat panel runs the extension's native binary with --output-format stream-json.
function findClaude() {
  let pid = process.ppid;
  for (let i = 0; i < 8 && pid > 1; i++) {
    let line;
    try { line = execFileSync("ps", ["-o", "ppid=,args=", "-p", String(pid)], { encoding: "utf8" }).trim(); }
    catch { return {}; }
    const m = line.match(/^(\d+)\s+(.*)$/);
    if (!m) return {};
    const [, ppid, args] = m;
    const bin = args.split(" ")[0];
    // the path before the first flag, for installs under folders with spaces (desktop app: ~/Library/Application Support/…)
    const exe = args.split(" -")[0];
    // bare "claude" = typed by hand in a terminal (shows up without its path)
    if (bin === "claude" || /\/claude$/.test(bin) || /\/share\/claude\/versions\//.test(bin) || /\/claude$/.test(exe)) {
      const desktop = /\/Application Support\/Claude\/claude-code\//.test(exe);
      return { claude_pid: pid, claude_ppid: Number(ppid), panel: !desktop && args.includes("stream-json"), desktop };
    }
    pid = Number(ppid);
  }
  return {};
}

function post(server, body, timeout) {
  return new Promise((resolve) => {
    const req = http.request({
      hostname: "127.0.0.1", port: server.port, path: "/event", method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body),
                 Authorization: `Bearer ${server.token}` },
      timeout,
    }, (res) => {
      let out = "";
      res.on("data", (c) => (out += c));
      res.on("end", () => resolve(out));
    });
    req.on("error", () => resolve(""));
    req.on("timeout", () => { req.destroy(); resolve(""); });
    req.end(body);
  });
}

async function main() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  let data;
  try { data = JSON.parse(input); } catch { return; }
  let server;
  try { server = JSON.parse(fs.readFileSync(SERVER_JSON, "utf8")); } catch { return; }

  const event = data.hook_event_name;
  const extra = findClaude();
  // The app the session runs in (com.apple.Terminal, com.googlecode.iterm2, com.microsoft.VSCode…): ↗ brings it forward
  if (process.env.__CFBundleIdentifier) extra.app_id = process.env.__CFBundleIdentifier;
  // Debug log: on while ~/.agent-huddle/log-events exists (touch it / rm it). One line per event, no tool input;
  // the last permission request is kept in full (last-permission.json), readable only by you.
  const logging = fs.existsSync(path.join(HOME_DIR, "log-events"));
  if (logging) {
    const line = { t: new Date().toISOString(), event, sid: data.session_id, tool: data.tool_name, reason: data.reason,
                   source: data.source, type: data.notification_type, ...extra };
    try { fs.appendFileSync(path.join(HOME_DIR, "events.log"), JSON.stringify(line) + "\n", { mode: 0o600 }); } catch {}
  }
  const body = JSON.stringify({ ...data, ...extra });
  const waits = event === "PermissionRequest";
  if (waits && logging) {
    const f = path.join(HOME_DIR, "last-permission.json");
    try { fs.writeFileSync(f, JSON.stringify(data, null, 2), { mode: 0o600 }); fs.chmodSync(f, 0o600); } catch {}
  }
  const until = Date.now() + WAIT_MS;
  let reply = await post(server, body, waits ? WAIT_MS : 2000);
  if (!waits) return;

  // Widget quit/restarted while holding the question: wait for the new one and ask it again.
  // Gives up after 30 s with no widget back (closed with ×), so VS Code's own prompt is all that's left.
  let gone = Date.now();
  while (/"retry"\s*:\s*true/.test(reply) && Date.now() < until - 5000 && Date.now() - gone < 30000) {
    await new Promise((r) => setTimeout(r, 3000));
    let next;
    try { next = JSON.parse(fs.readFileSync(SERVER_JSON, "utf8")); } catch { continue; }
    if (next.pid === server.pid) continue;  // still the old one shutting down
    server = next;
    reply = await post(server, body, until - Date.now());
    gone = Date.now();
  }

  let decision, updatedInput, updatedPermissions;
  try { ({ decision, updatedInput, updatedPermissions } = JSON.parse(reply)); } catch { return; }
  if (decision !== "allow" && decision !== "deny") return;
  const out = { behavior: decision };
  // AskUserQuestion answered in the widget: original questions + an `answers` map
  if (decision === "allow" && updatedInput && typeof updatedInput === "object") out.updatedInput = updatedInput;
  // "Always …" button: one of Claude Code's own permission_suggestions, echoed back ("Yes, and don't ask again")
  if (decision === "allow" && Array.isArray(updatedPermissions) && updatedPermissions.length) out.updatedPermissions = updatedPermissions;
  if (decision === "deny") out.message = "Denied from the Agent Huddle widget.";
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: out },
  }));
}

main().catch(() => {}).finally(() => process.exit(0));
