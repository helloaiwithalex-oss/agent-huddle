#!/usr/bin/env node
// Agent Huddle stress test. Runs its OWN copy of the widget (separate state folder, test endpoints on), pipes
// fake hook events through the real hook.js, clicks Allow/Deny/answers through /test/answer and checks what
// hook.js hands back to Claude. Real Claude sessions never see it.
//
//   node test/sim.mjs <widget binary>     (build one: swiftc -O -o /tmp/AgentHuddleTest app/main.swift -framework Cocoa -framework SwiftUI -framework Network)
//
// Results + UI snapshots go to test/results/.
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOOK = path.join(HERE, "..", "hook.js");
const BIN = process.argv[2];
if (!BIN || !fs.existsSync(BIN)) { console.error("usage: node test/sim.mjs <widget binary>"); process.exit(2); }
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), "huddle-test-"));
const OUT = path.join(HERE, "results");
fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });
const ENV = { ...process.env, AGENT_HUDDLE_HOME: HOME, AGENT_HUDDLE_TEST: "1" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- widget ----------
let widget;
async function startWidget() {
  try { fs.unlinkSync(path.join(HOME, "server.json")); } catch {}
  widget = spawn(BIN, [], { env: ENV, stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try { const s = JSON.parse(fs.readFileSync(path.join(HOME, "server.json"), "utf8")); if (s.pid === widget.pid) return s; } catch {}
    await sleep(100);
  }
  throw new Error("widget didn't start");
}
async function stopWidget() {
  if (!widget || widget.exitCode !== null) return;
  const w = widget;
  w.kill("SIGTERM");
  await new Promise((r) => { w.once("exit", r); setTimeout(r, 3000); });
}
const server = () => JSON.parse(fs.readFileSync(path.join(HOME, "server.json"), "utf8"));
function api(route, body = {}, { token, raw } = {}) {
  const s = server();
  const data = raw ?? JSON.stringify(body);
  return new Promise((resolve) => {
    const req = http.request({ hostname: "127.0.0.1", port: s.port, path: route, method: "POST",
      headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data), Authorization: `Bearer ${token ?? s.token}` },
      timeout: 5000 }, (res) => { let o = ""; res.on("data", (c) => (o += c)); res.on("end", () => resolve({ status: res.statusCode, body: o })); });
    req.on("error", (e) => resolve({ status: 0, body: String(e) }));
    req.on("timeout", () => { req.destroy(); resolve({ status: 0, body: "timeout" }); });
    req.end(data);
  });
}
const state = async () => JSON.parse((await api("/test/state")).body);
const agent = async (sid) => (await state()).agents.find((a) => a.id === sid);
const click = (sid, opts) => api("/test/answer", { session_id: sid, ...opts });
async function snap(name) {
  try { fs.unlinkSync(path.join(HOME, "snapshot.png")); } catch {}
  process.kill(widget.pid, "SIGUSR1");
  for (let i = 0; i < 20; i++) { await sleep(100); if (fs.existsSync(path.join(HOME, "snapshot.png"))) break; }
  try { fs.copyFileSync(path.join(HOME, "snapshot.png"), path.join(OUT, name + ".png")); } catch {}
}
// wait until fn() is truthy (polls the widget)
async function until(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(80); }
  return null;
}

// ---------- hook.js ----------
function hook(payload, { raw, env = ENV } = {}) {
  const t0 = Date.now();
  const p = spawn("node", [HOOK], { env, stdio: ["pipe", "pipe", "pipe"] });
  let out = "", err = "";
  p.stdout.on("data", (c) => (out += c));
  p.stderr.on("data", (c) => (err += c));
  p.stdin.end(raw ?? JSON.stringify(payload));
  const done = new Promise((resolve) => p.on("exit", (code) => {
    let json = null; try { json = out ? JSON.parse(out) : null; } catch {}
    resolve({ code, out, err, json, ms: Date.now() - t0 });
  }));
  return { proc: p, done };
}
const base = (sid, event, extra = {}) => ({ session_id: sid, hook_event_name: event, cwd: "/tmp/proj",
  transcript_path: "", permission_mode: "default", ...extra });
const ask = (sid, tool, input, extra = {}) => hook(base(sid, "PermissionRequest", { tool_name: tool, tool_input: input, ...extra }));
const fire = (sid, event, extra) => hook(base(sid, event, extra)).done;
const decision = (r) => r.json?.hookSpecificOutput?.decision;
let n = 0;
const sid = (tag) => `test-${tag}-${++n}`;
async function waitAsks(s, count) { return until(async () => { const a = await agent(s); return a && a.asks.length >= count ? a : null; }); }

// ---------- reporting ----------
const results = [];
function check(scenario, name, ok, detail = "") {
  results.push({ scenario, name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${scenario} · ${name}${detail ? "  — " + detail : ""}`);
}
const findings = [];
const note = (s) => { findings.push(s); console.log("NOTE  " + s); };

// ---------- scenarios ----------
const S = {};

S["not running"] = async () => {
  // no widget at all: hook must stay silent and quick, so Claude shows its normal prompt
  const env = { ...ENV, AGENT_HUDDLE_HOME: fs.mkdtempSync(path.join(os.tmpdir(), "huddle-none-")) };
  let r = await hook(base("x", "PermissionRequest", { tool_name: "Bash", tool_input: { command: "ls" } }), { env }).done;
  check("not running", "no server.json → silent, exit 0", r.code === 0 && r.out === "", `${r.ms} ms`);
  // stale server.json (widget crashed, file left behind)
  fs.writeFileSync(path.join(env.AGENT_HUDDLE_HOME, "server.json"), JSON.stringify({ port: 1, token: "x", pid: 999999 }));
  r = await hook(base("x", "PermissionRequest", { tool_name: "Bash", tool_input: { command: "ls" } }), { env }).done;
  check("not running", "stale server.json → silent, exit 0", r.code === 0 && r.out === "", `${r.ms} ms`);
  check("not running", "stale server.json → quick (<3 s)", r.ms < 3000, `${r.ms} ms`);
};

S["2 at once"] = async () => {
  const a = sid("two"), b = sid("two");
  await fire(a, "UserPromptSubmit", { prompt: "agent A" });
  await fire(b, "UserPromptSubmit", { prompt: "agent B" });
  const ha = ask(a, "Bash", { command: "rm -rf build" }), hb = ask(b, "Bash", { command: "npm publish" });
  const ok = await until(async () => { const st = await state(); return st.agents.filter((x) => [a, b].includes(x.id) && x.asks.length === 1).length === 2; });
  check("2 at once", "both asks show up at the same time (no queue between agents)", ok);
  await snap("01-two-agents-asking");
  const order = (await state()).order;
  check("2 at once", "agents waiting for you are at the top of the list", order.indexOf(a) < 2 && order.indexOf(b) < 2, `positions ${order.indexOf(a)}, ${order.indexOf(b)}`);
  await click(b, { decision: "deny" });
  await click(a, { decision: "allow" });
  const [ra, rb] = await Promise.all([ha.done, hb.done]);
  check("2 at once", "A gets allow", decision(ra)?.behavior === "allow", JSON.stringify(decision(ra)));
  check("2 at once", "B gets deny", decision(rb)?.behavior === "deny", JSON.stringify(decision(rb)));
  if (decision(rb)?.message) note(`deny message sent to Claude: "${decision(rb).message}"`);
};

S["5 at once"] = async () => {
  const ids = [1, 2, 3, 4, 5].map(() => sid("five"));
  const hs = ids.map((s, i) => ask(s, "Bash", { command: `echo agent-${i}` }));
  const ok = await until(async () => (await state()).agents.filter((x) => ids.includes(x.id) && x.asks.length === 1).length === 5, 6000);
  check("5 at once", "all 5 asks held", ok);
  await snap("02-five-agents-asking");
  const want = ["deny", "allow", "deny", "allow", "allow"];
  for (const i of [3, 0, 4, 1, 2]) await click(ids[i], { decision: want[i] });  // answered out of order
  const rs = await Promise.all(hs.map((h) => h.done));
  const right = rs.every((r, i) => decision(r)?.behavior === want[i]);
  check("5 at once", "each agent got its own answer (answered out of order)", right, rs.map((r) => decision(r)?.behavior).join(","));
};

S["3 in one agent"] = async () => {
  const s = sid("multi");
  const cmds = ["git push", "npm test", "rm notes.txt"];
  const hs = cmds.map((c) => ask(s, "Bash", { command: c }));
  const a = await waitAsks(s, 3);
  const cmdOf = (x) => x.full.split("\n")[1].replace(/^\$ /, "");
  check("3 in one agent", "3 asks held for one agent", a?.asks.length === 3, a ? a.asks.map(cmdOf).join(" | ") : "");
  await snap("03-three-asks-one-agent");
  // the card shows the first; answer it, the next should take its place
  const order = a ? a.asks.map(cmdOf) : [];
  await click(s, { index: 0, decision: "allow" });
  const after = await until(async () => { const x = await agent(s); return x && x.asks.length === 2 ? x : null; });
  check("3 in one agent", "answering the first leaves 2, next one moves up", after && cmdOf(after.asks[0]) === order[1]);
  await click(s, { index: 0, decision: "deny" });
  await click(s, { index: 0, decision: "allow" });
  const rs = await Promise.all(hs.map((h) => h.done));
  const byCmd = Object.fromEntries(cmds.map((c, i) => [c, decision(rs[i])?.behavior]));
  const expected = Object.fromEntries(order.map((t, i) => [t, ["allow", "deny", "allow"][i]]));
  check("3 in one agent", "every ask got the answer clicked for it", cmds.every((c) => byCmd[c] === expected[c]), JSON.stringify(byCmd));
  const x = await agent(s);
  check("3 in one agent", "agent back to working, no asks left", x && x.asks.length === 0 && x.mood === "working", x?.mood);
};

S["questions"] = async () => {
  const s = sid("q");
  const input = { questions: [
    { question: "Which colour?", header: "Colour", multiSelect: false, options: [{ label: "Lime", description: "brand" }, { label: "Black", description: "" }] },
    { question: "Which extras?", header: "Extras", multiSelect: true, options: [{ label: "Sound" }, { label: "Captions" }, { label: "Logo" }] },
  ] };
  const h = ask(s, "AskUserQuestion", input);
  const a = await waitAsks(s, 1);
  check("questions", "shows as a question card (2 questions)", a?.asks[0].questions === 2, a?.detail);
  await snap("04-question-card");
  await click(s, { answers: { "Which colour?": "Lime", "Which extras?": "Sound, Logo" } });
  const r = await h.done;
  const d = decision(r);
  check("questions", "allow + original questions + answers sent back",
    d?.behavior === "allow" && d.updatedInput?.questions?.length === 2 && d.updatedInput?.answers?.["Which extras?"] === "Sound, Logo", JSON.stringify(d?.updatedInput?.answers));
};

S["always buttons"] = async () => {
  const s = sid("always");
  const sugg = [
    { type: "addRules", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }], behavior: "allow", destination: "localSettings" },
    { type: "addRules", rules: [{ toolName: "Bash", ruleContent: "rm:*" }], behavior: "deny", destination: "localSettings" },
    { type: "setMode", mode: "acceptEdits", destination: "session" },
  ];
  const h = ask(s, "Bash", { command: "npm test" }, { permission_suggestions: sugg });
  const a = await waitAsks(s, 1);
  check("always buttons", "deny-type suggestion hidden, 2 buttons left", a?.asks[0].suggestions.length === 2, JSON.stringify(a?.asks[0].suggestions));
  await snap("05-always-buttons");
  await click(s, { decision: "allow", always: 0 });
  const d = decision(await h.done);
  check("always buttons", "allow + that rule sent back as updatedPermissions",
    d?.behavior === "allow" && d.updatedPermissions?.[0]?.rules?.[0]?.ruleContent === "npm test:*", JSON.stringify(d?.updatedPermissions));
};

S["what the card shows"] = async () => {
  const s = sid("show");
  const long = "curl -s https://example.com/api && " + Array.from({ length: 60 }, (_, i) => `echo step-${i}`).join(" && ");
  const h1 = ask(s, "Bash", { command: long, description: "Long chained command" });
  const h2 = ask(s, "Edit", { file_path: "/tmp/proj/src/app.js", old_string: "const a = 1;\n".repeat(30), new_string: "const a = 2;\n".repeat(30) });
  const h3 = ask(s, "mcp__github__create_issue", { repo: "x/y", title: "Bug", body: "z".repeat(500) });
  const h4 = ask(s, "Bash", { command: "echo '日本語 🚀 émoji ✅'" });
  const a = await waitAsks(s, 4);
  const t = a ? a.asks.map((x) => x.full) : [];
  const bash = (t.find((x) => x.includes("$ curl")) || "").split("\n").slice(1).join("\n");
  check("what the card shows", "long Bash command shown in full", bash.length >= long.length, `${long.length} chars → card has ${bash.length}`);
  const edit = t.find((x) => x.startsWith("Edit")) || "";
  check("what the card shows", "Edit shows what changes (not just the path)", /const a = 2/.test(edit), `card: "${edit.split("\n").slice(0, 2).join(" ⏎ ")}…"`);
  const mcp = t.find((x) => /^github · create issue/.test(x)) || "";
  check("what the card shows", "MCP tool shown by a readable name", mcp.length > 0, `card: "${(mcp || t[2] || "").split("\n")[0]}"`);
  check("what the card shows", "unicode/emoji kept intact", t.some((x) => x.includes("日本語 🚀 émoji ✅")));
  await snap("06-long-command-card");
  for (let i = 0; i < 4; i++) await click(s, { index: 0, decision: "deny" });
  await Promise.all([h1.done, h2.done, h3.done, h4.done]);
};

S["answered in VS Code"] = async () => {
  // (a) "In VS Code" button: hook prints nothing → Claude shows its own prompt
  let s = sid("vsc");
  let h = ask(s, "Bash", { command: "ls" });
  await waitAsks(s, 1);
  await click(s, { decision: "vscode" });
  let r = await h.done;
  check("answered in VS Code", "'In VS Code' button → hook silent (normal prompt)", r.code === 0 && r.out === "");
  // (b) answered in VS Code: the tool ran, PostToolUse arrives → card clears, hook let go
  s = sid("vsc");
  const input = { command: "git status" };
  h = ask(s, "Bash", input);
  await waitAsks(s, 1);
  await fire(s, "PostToolUse", { tool_name: "Bash", tool_input: input, tool_response: {} });
  r = await h.done;
  let a = await agent(s);
  check("answered in VS Code", "PostToolUse clears the card and frees the hook", a?.asks.length === 0 && r.out === "", `${a?.asks.length} asks left`);
  // (c) Stop while a question is open (you pressed Esc) → cleared
  s = sid("vsc");
  h = ask(s, "Bash", { command: "make" });
  await waitAsks(s, 1);
  await fire(s, "Stop", { last_assistant_message: "ok" });
  r = await h.done;
  a = await agent(s);
  check("answered in VS Code", "Stop clears open asks", a?.asks.length === 0 && a?.mood === "idle", a?.mood);
  // (d) Claude cancels the hook (hook process killed, e.g. answered in VS Code) → card goes
  s = sid("vsc");
  h = ask(s, "Bash", { command: "sleep 1" });
  await waitAsks(s, 1);
  h.proc.kill("SIGKILL");
  const gone = await until(async () => (await agent(s))?.asks.length === 0);
  check("answered in VS Code", "hook killed → card disappears", !!gone);
};

S["widget restart"] = async () => {
  const s = sid("restart");
  const h = ask(s, "Bash", { command: "deploy" });
  await waitAsks(s, 1);
  const t0 = Date.now();
  await stopWidget();
  await startWidget();
  const back = await waitAsks(s, 1);
  check("widget restart", "held question shows again on the new widget", !!back, back ? `${Date.now() - t0} ms` : "");
  if (back) await click(s, { decision: "allow" });
  const r = await Promise.race([h.done, sleep(8000).then(() => null)]);
  check("widget restart", "answer on the new widget reaches Claude", decision(r)?.behavior === "allow");
};

S["bad input"] = async () => {
  let r = await hook(null, { raw: "{not json" }).done;
  check("bad input", "malformed stdin → silent exit 0", r.code === 0 && r.out === "");
  r = await hook(null, { raw: "" }).done;
  check("bad input", "empty stdin → silent exit 0", r.code === 0 && r.out === "");
  r = await hook({ hook_event_name: "PermissionRequest", tool_name: "Bash" }).done;
  check("bad input", "event with no session_id → silent exit 0", r.code === 0 && r.out === "");
  const res = await api("/event", base("intruder", "UserPromptSubmit"), { token: "wrong" });
  check("bad input", "wrong token → 403", res.status === 403);
  const t = await api("/test/state", {}, { token: "wrong" });
  check("bad input", "test endpoint needs the token too", t.status === 403);
  const big = JSON.stringify(base(sid("big"), "PreToolUse", { tool_name: "Write", tool_input: { file_path: "/x", content: "x".repeat(5_000_000) } }));
  r = await hook(null, { raw: big }).done;
  const alive = (await api("/test/state")).status === 200;
  check("bad input", "5 MB event → widget survives", alive && r.code === 0, `${r.ms} ms`);
  const mode = (fs.statSync(path.join(HOME, "server.json")).mode & 0o777).toString(8);
  check("bad input", "server.json readable only by you (600)", mode === "600", mode);
  const lp = path.join(HOME, "last-permission.json");
  if (fs.existsSync(lp)) {
    const m = (fs.statSync(lp).mode & 0o777).toString(8);
    check("bad input", "last-permission.json (holds full commands) readable only by you", m === "600", m);
  }
};

S["session lifecycle"] = async () => {
  const s = sid("life");
  await fire(s, "SessionStart", { source: "startup" });
  let a = await agent(s);
  check("session lifecycle", "SessionStart alone → hidden (VS Code background sessions)", a && !a.seen);
  await fire(s, "UserPromptSubmit", { prompt: "/review the login page please" });
  a = await agent(s);
  check("session lifecycle", "first prompt → shown and named", a?.seen && a?.name === "Review · the login page please", `name: "${a?.name}"`);
  await fire(s, "SubagentStart", {}); await fire(s, "SubagentStart", {});
  a = await agent(s);
  check("session lifecycle", "helpers counted", a?.helpers === 2);
  await fire(s, "Stop", { last_assistant_message: "All done." });
  a = await agent(s);
  check("session lifecycle", "Stop → helpers reset", a?.helpers === 0, `mood ${a?.mood}`);
  await fire(s, "SessionEnd", { reason: "prompt_input_exit" });
  a = await agent(s);
  check("session lifecycle", "SessionEnd → shown as closed", a?.ended && a?.mood === "done");
  const t0 = Date.now();
  const gone = await until(async () => !(await agent(s)), 15000);
  check("session lifecycle", "closed bot leaves within ~10 s (was 3 min)", !!gone, `${Date.now() - t0} ms`);
  await fire(s, "UserPromptSubmit", { prompt: "again" });  // resumed session
  a = await agent(s);
  check("session lifecycle", "resumed after SessionEnd → active again", a && !a.ended);
};

S["load"] = async () => {
  // 50 agents × a burst of normal events: how long does each hook take, does the widget keep up?
  const ids = Array.from({ length: 50 }, () => sid("load"));
  const t0 = Date.now();
  const times = [];
  for (let round = 0; round < 3; round++) {
    const rs = await Promise.all(ids.map((s, i) => hook(base(s, round === 0 ? "UserPromptSubmit" : "PreToolUse",
      { prompt: `job ${i}`, tool_name: "Read", tool_input: { file_path: `/tmp/f${i}` } })).done));
    times.push(...rs.map((r) => r.ms));
  }
  const st = await state();
  const shown = st.agents.filter((a) => ids.includes(a.id)).length;
  check("load", "50 agents all tracked", shown === 50, `${shown}`);
  times.sort((x, y) => x - y);
  const p50 = times[times.length >> 1], p95 = times[Math.floor(times.length * 0.95)];
  note(`50 agents firing at the same instant (stress only): hook p50 ${p50} ms · p95 ${p95} ms`);
  const burst = await Promise.all(ids.slice(0, 10).map((s) => fire(s, "PreToolUse", { tool_name: "Read", tool_input: {} })));
  const worst = Math.max(...burst.map((r) => r.ms));
  check("load", "10 agents firing at once: every hook done in under 1 s", worst < 1000, `slowest ${worst} ms`);
  const one = [];
  for (let i = 0; i < 10; i++) one.push((await fire(ids[0], "PreToolUse", { tool_name: "Read", tool_input: {} })).ms);
  one.sort((x, y) => x - y);
  note(`single hook event (quiet machine): median ${one[5]} ms. Claude waits for this on every tool call.`);
  await snap("07-fifty-agents");
  const ps = execFileSync("ps", ["-o", "rss=,%cpu=", "-p", String(widget.pid)], { encoding: "utf8" }).trim().split(/\s+/);
  note(`widget with ${st.agents.length} agents: ${Math.round(+ps[0] / 1024)} MB RAM, ${ps[1]}% CPU`);
};

// ---------- run ----------
const only = process.argv.slice(3);
try {
  await S["not running"]();
  await startWidget();
  for (const [name, fn] of Object.entries(S)) {
    if (name === "not running" || (only.length && !only.includes(name))) continue;
    try { await fn(); } catch (e) { check(name, "scenario crashed", false, String(e.stack || e)); }
  }
} finally {
  await stopWidget();
}
const failed = results.filter((r) => !r.ok);
const md = [`# Agent Huddle test run · ${new Date().toISOString()}`, "",
  `**${results.length - failed.length}/${results.length} passed**`, "",
  "| | Scenario | Check | Detail |", "|---|---|---|---|",
  ...results.map((r) => `| ${r.ok ? "✅" : "❌"} | ${r.scenario} | ${r.name} | ${r.detail.replace(/\|/g, "\\|").replace(/\n/g, " ").slice(0, 200)} |`),
  "", "## Notes", ...findings.map((f) => `- ${f}`)].join("\n");
fs.writeFileSync(path.join(OUT, "report.md"), md);
console.log(`\n${results.length - failed.length}/${results.length} passed · report: ${path.join(OUT, "report.md")}`);
fs.rmSync(HOME, { recursive: true, force: true });
process.exit(failed.length ? 1 : 0);
