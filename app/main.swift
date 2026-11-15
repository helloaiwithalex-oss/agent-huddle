// Agent Huddle: a small floating panel with one bot per Claude Code session on this Mac.
// hook.js (registered in ~/.claude/settings.json by install.sh) POSTs every hook event to the local server
// below. PermissionRequest events are held open until you click Allow / Deny / In VS Code.
// Jump and close requests are dropped as files into ~/.agent-huddle/commands/, which the Agent Huddle
// VS Code helper picks up (it owns the tabs). Build with ../build.sh.
import Cocoa
import Network
import SwiftUI

// AGENT_HUDDLE_HOME: another state folder (the test harness runs its own copy there, apart from real sessions).
// AGENT_HUDDLE_TEST=1: turns on the /test/* endpoints and mutes sounds. Both unset = normal widget.
let env = ProcessInfo.processInfo.environment
let stateDir = env["AGENT_HUDDLE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-huddle")
let testMode = env["AGENT_HUDDLE_TEST"] == "1"
let commandsDir = stateDir.appendingPathComponent("commands")  // jump/close requests for the VS Code helper
let serverFile = stateDir.appendingPathComponent("server.json")

let lime = Color(red: 0xd7 / 255, green: 1, blue: 0x3f / 255)
func rgb(_ hex: Int) -> Color {
    Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
}
let palette: [Color] = [rgb(0x4a86f7), rgb(0xff7aa8), rgb(0xffa64d), rgb(0x9b7bff), rgb(0x3fd6a6), rgb(0xffd23f)]

// MARK: - Model

enum Mood { case idle, working, needsYou, done }

struct Ask: Identifiable {
    let id: String
    let text: String                // one-line title: what it wants to do
    var code: [CodeLine] = []       // the whole command, or the diff of an edit
    var questions: [Question] = []  // AskUserQuestion: answered right here instead of Allow/Deny
    var input: [String: Any] = [:]  // original tool input, echoed back with the answers
    var key = ""                    // toolKey(name, input): matches the tool's result when it's answered in VS Code
    var suggestions: [[String: Any]] = []  // Claude Code's "Yes, and don't ask again" options (permission_suggestions)
}

/// Button text for one "don't ask again" suggestion, e.g. "Always · Bash(npm test:*)".
func suggestionLabel(_ s: [String: Any], cwd: String = "") -> String {
    func short(_ p: String) -> String {
        var p = rel(p, cwd)
        while p.hasPrefix("//") { p.removeFirst() }
        return p
    }
    var text: String
    switch s["type"] as? String ?? "" {
    case "addRules", "replaceRules":
        let rules = (s["rules"] as? [[String: Any]] ?? []).map { r -> String in
            let tool = r["toolName"] as? String ?? "tool"
            if let c = r["ruleContent"] as? String, !c.isEmpty { return "\(tool)(\(short(c)))" }
            return tool
        }
        text = "Always · " + (rules.isEmpty ? "allow" : rules.joined(separator: ", "))
    case "addDirectories":
        text = "Always · allow folder " + (s["directories"] as? [String] ?? []).map(short).joined(separator: ", ")
    case "setMode":
        let mode = s["mode"] as? String ?? ""
        text = "Yes + " + (mode == "acceptEdits" ? "auto-accept edits" : mode == "auto" ? "auto mode" : "\(mode) mode")
    default:
        text = "Always allow"
    }
    if s["destination"] as? String == "session" { text += " (this session)" }
    return clip(text, 70)
}

/// Same tool + same input → same key (how a held question is matched to its tool result).
func toolKey(_ name: String, _ input: Any?) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: input ?? [String: Any](), options: [.sortedKeys])) ?? Data()
    return name + "|" + (String(data: data, encoding: .utf8) ?? "")
}

struct Question: Identifiable {
    let id: Int
    let text: String
    let header: String
    let options: [(label: String, desc: String)]
    let multi: Bool
}

func questionsIn(_ input: [String: Any]) -> [Question] {
    let qs = input["questions"] as? [[String: Any]] ?? []
    return qs.enumerated().compactMap { i, q in
        guard let text = q["question"] as? String else { return nil }
        let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> (label: String, desc: String)? in
            guard let l = o["label"] as? String else { return nil }
            return (l, o["description"] as? String ?? "")
        }
        return Question(id: i, text: text, header: q["header"] as? String ?? "", options: opts, multi: q["multiSelect"] as? Bool == true)
    }
}

struct Agent: Identifiable {
    let id: String  // Claude session_id
    var name = "Claude"
    var named = false
    var seen = false  // got a prompt / tool / question / transcript content; VS Code's idle background sessions never do
    var titleRank = 0  // name source: 0 prompt, 1 VS Code's auto title, 2 a tab rename, 3 slash command (Review · X …)
    var mood: Mood = .idle
    var detail = "starting up"
    var color: Color
    var seed = Double.random(in: 0...10)
    var claudePid = 0
    var claudePpid = 0
    var panel = false  // VS Code chat panel session (no terminal to type "go" into)
    var desktop = false  // Claude desktop app session (jump = bring the app forward; × just clears the row)
    var appId = ""  // the app the session runs in (Terminal, iTerm, VS Code…), from the hook's environment
    /// Runs outside VS Code and the desktop app (Terminal, iTerm…): ↗ brings that app forward, × clears the row.
    var otherApp: Bool { !desktop && !panel && !appId.isEmpty && appId != "com.microsoft.VSCode" }
    /// Name for the "hand it back" button: "In VS Code", "In Claude app", "In Terminal"…
    var appName: String {
        if desktop { return "Claude app" }
        guard otherApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId) else { return "VS Code" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    var helpers = 0
    var asks: [Ask] = []
    var endedAt: Date?
    var lastSeen = Date()
    var transcript: String?
    var cwd = ""
    var step: Step?  // from the "▰▰▱ 3/6 · Label" progress lines skills post
    var actions: [Action] = []  // live tool calls read from the transcript, oldest first
}

struct Step: Equatable {
    let n: Int
    let total: Int
    let label: String
    var fraction: Double { total > 0 ? min(1, Double(n) / Double(total)) : 0 }
}

enum ActState { case running, done, failed }

struct CodeLine: Hashable {
    enum Kind { case plain, add, del, cmd, dim }
    let text: String
    let kind: Kind
}

struct Action: Identifiable {
    let id: String
    let tool: String
    let title: String  // file name, command description, pattern…
    let path: String   // right-hand label in the code pane
    let lead: [CodeLine]  // from the call itself (diff, command)
    var result = ""
    var state = ActState.running
}

/// Where we are in each transcript file (not published, so polling doesn't redraw).
struct Tail {
    var offset: UInt64 = 0
    var rest = Data()
    var started = false
    var skipFirst = false
}

final class Store: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var collapsed = UserDefaults.standard.bool(forKey: "collapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "collapsed") }
    }
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    var held: [String: NWConnection] = [:]  // ask id -> the hook request waiting for your click
    @Published var openId: String?  // agent shown in the big live view
    @Published var pickedAction: String?  // action picked in that view (nil = follow the latest)
    var tails: [String: Tail] = [:]
    var useKeys: [String: String] = [:]  // transcript tool_use id -> toolKey, to spot results of held questions
    private var nextColor = 0

    var shown: [Agent] {  // seen agents; the ones waiting for you first, otherwise in arrival order
        agents.filter { $0.seen }.enumerated().sorted { x, y in
            let (px, py) = (x.element.mood == .needsYou ? 0 : 1, y.element.mood == .needsYou ? 0 : 1)
            return px != py ? px < py : x.offset < y.offset
        }.map(\.element)
    }
    var needsYouCount: Int { agents.filter { $0.mood == .needsYou }.count }

    private func index(_ sid: String) -> Int {
        if let i = agents.firstIndex(where: { $0.id == sid }) { return i }
        agents.append(Agent(id: sid, color: palette[nextColor % palette.count]))
        nextColor += 1
        return agents.count - 1
    }

    /// Returns an ask id when the connection must stay open for a decision.
    func handle(_ e: [String: Any], conn: NWConnection) -> String? {
        guard let sid = e["session_id"] as? String else { return nil }
        let event = e["hook_event_name"] as? String ?? ""
        let i = index(sid)
        var a = agents[i]
        let before = a.mood
        var holdId: String?
        a.lastSeen = Date()
        a.endedAt = nil
        if let p = e["claude_pid"] as? Int, p > 0 { a.claudePid = p }
        if let p = e["claude_ppid"] as? Int, p > 0 { a.claudePpid = p }
        if let p = e["panel"] as? Bool { a.panel = p }
        if let p = e["desktop"] as? Bool { a.desktop = p }
        if let p = e["app_id"] as? String, !p.isEmpty { a.appId = p }
        if let p = e["transcript_path"] as? String, !p.isEmpty { a.transcript = p }
        if let p = e["cwd"] as? String, !p.isEmpty, a.cwd.isEmpty { a.cwd = p }

        switch event {
        case "SessionStart":
            a.mood = .idle
            a.detail = "ready"
        case "UserPromptSubmit":
            a.seen = true
            settle(&a, a.asks.map(\.id))
            if !a.named, let p = e["prompt"] as? String {
                a.named = true
                if let n = skillName(p) { a.name = n; a.titleRank = 3 } else if a.titleRank == 0 { a.name = nameFor(p) }
            }
            if let s = a.step, s.n >= s.total { a.step = nil }  // finished job's bar → cleared by the new request
            a.mood = .working
            a.detail = "thinking…"
        case "PreToolUse":
            a.seen = true
            if a.asks.isEmpty { a.mood = .working }
            a.detail = describe(e)
        case "PostToolUse", "PostToolUseFailure":
            // the tool ran, so its question was answered in VS Code
            let key = toolKey(e["tool_name"] as? String ?? "", e["tool_input"])
            settle(&a, a.asks.filter { $0.key == key }.map(\.id))
            if a.asks.isEmpty && a.mood != .working { a.mood = .working }
        case "SubagentStart":
            a.helpers += 1
        case "SubagentStop":
            a.helpers = max(0, a.helpers - 1)
        case "PermissionRequest":
            a.seen = true
            let id = UUID().uuidString
            held[id] = conn
            let input = e["tool_input"] as? [String: Any] ?? [:]
            let qs = e["tool_name"] as? String == "AskUserQuestion" ? questionsIn(input) : []
            let sugg = (e["permission_suggestions"] as? [[String: Any]] ?? []).filter { s in
                // only "allow"-side updates can be sent back from a hook
                s["type"] as? String != "addRules" || (s["behavior"] as? String ?? "allow") == "allow"
            }
            a.asks.append(Ask(id: id, text: askText(e), code: askCode(e), questions: qs, input: input,
                              key: toolKey(e["tool_name"] as? String ?? "", input), suggestions: sugg))
            a.mood = .needsYou
            a.detail = qs.isEmpty ? "wants permission" : "has a question for you"
            holdId = id
        case "Notification":
            let type = e["notification_type"] as? String ?? ""
            if type == "permission_prompt" && a.asks.isEmpty {
                a.mood = .needsYou
                a.detail = "needs permission · answer in \(a.appName)"
            } else if type == "elicitation_dialog" || type == "agent_needs_input" {
                a.mood = .needsYou
                a.detail = "has a question for you in \(a.appName)"
            }
        case "Stop":
            a.helpers = 0
            settle(&a, a.asks.map(\.id))
            if a.asks.isEmpty {
                a.mood = .idle
                a.detail = "done · waiting for you"
            }
        case "SessionEnd":
            settle(&a, a.asks.map(\.id))
            a.mood = .done
            a.detail = "session closed"
            a.endedAt = Date()
        default:
            break
        }
        agents[i] = a
        if a.mood != before && a.mood == .needsYou && !muted && !testMode {
            NSSound(named: "Glass")?.play()
        }
        return holdId
    }

    /// decision: "allow" / "deny", or nil to hand the question back to VS Code.
    /// always: one of the ask's suggestions, sent back as updatedPermissions ("Yes, and don't ask again").
    func answer(_ askId: String, _ decision: String?, always: [String: Any]? = nil) {
        if let c = held.removeValue(forKey: askId) {
            var body: [String: Any] = [:]
            if let d = decision { body["decision"] = d }
            if decision == "allow", let s = always { body["updatedPermissions"] = [s] }
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            Server.reply(c, String(data: data, encoding: .utf8) ?? "{}")
        }
        clearAsk(askId, detail: decision == "allow" ? (always != nil ? "always allowed · back to work" : "allowed · back to work")
                              : decision == "deny" ? "denied" : "asking in %APP%")
    }

    /// AskUserQuestion answered in the widget: allow it with the answers filled in (question text → label(s)).
    func answer(_ askId: String, answers: [String: String]) {
        guard let i = agents.firstIndex(where: { $0.asks.contains { $0.id == askId } }),
              let ask = agents[i].asks.first(where: { $0.id == askId }) else { return }
        if let c = held.removeValue(forKey: askId) {
            var input = ask.input
            input["answers"] = answers
            let body: [String: Any] = ["decision": "allow", "updatedInput": input]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            Server.reply(c, String(data: data, encoding: .utf8) ?? "{}")
        }
        clearAsk(askId, detail: "answered · back to work")
    }

    /// Questions answered in VS Code (their tool ran / was refused, or the turn moved on): let the waiting
    /// hooks go with no decision and take the cards off. Works on the agent copy being edited.
    func settle(_ a: inout Agent, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        for id in ids { if let c = held.removeValue(forKey: id) { Server.reply(c, "{}") } }
        a.asks.removeAll { ids.contains($0.id) }
        if a.asks.isEmpty && a.mood == .needsYou {
            a.mood = .working
            a.detail = "answered in \(a.appName)"
        }
    }

    /// The hook went away without our answer (answered in VS Code, or it timed out).
    func dropAsk(_ askId: String) {
        guard held.removeValue(forKey: askId) != nil else { return }
        clearAsk(askId, detail: "answered in %APP%")
    }

    private func clearAsk(_ askId: String, detail: String) {
        guard let i = agents.firstIndex(where: { $0.asks.contains { $0.id == askId } }) else { return }
        agents[i].asks.removeAll { $0.id == askId }
        if agents[i].asks.isEmpty && agents[i].mood == .needsYou {
            agents[i].mood = .working
            agents[i].detail = detail.replacingOccurrences(of: "%APP%", with: agents[i].appName)
        }
    }

    func focus(_ a: Agent) {
        if a.desktop { bringAppForward("com.anthropic.claudefordesktop"); return }
        if a.otherApp { bringAppForward(a.appId); return }
        // Chat-panel tabs: the helper extension opens the session by id through the Claude extension's
        // own command (reveals its tab, or reopens it), so VS Code never asks "allow extension to open URI?".
        if a.panel, a.id.range(of: #"^[0-9a-fA-F-]{36}$"#, options: .regularExpression) != nil {
            writeCommand("focus", a, extra: ["session_id": a.id])
            bringVSCodeForward()
            return
        }
        if a.claudePid > 0 { writeCommand("focus", a) }
        bringVSCodeForward()
    }

    /// × on a row: closes the session's tab in VS Code (terminal tab by pid, chat tab by its title, via the
    /// Agent Huddle helper extension). Already-closed sessions just leave the list.
    func close(_ a: Agent) {
        guard let i = agents.firstIndex(where: { $0.id == a.id }) else { return }
        // desktop app chats can't be closed from outside: × just clears the row (it comes back if the chat is used again)
        if a.desktop || a.otherApp || a.endedAt != nil || a.claudePid == 0 || kill(pid_t(a.claudePid), 0) != 0 {
            agents.remove(at: i)
            if openId == a.id { openId = nil }
            return
        }
        for ask in a.asks { answer(ask.id, nil) }
        var extra: [String: Any] = a.titleRank == 1 || a.titleRank == 2 ? ["title": a.name] : [:]
        if a.panel { extra["session_id"] = a.id }  // chat tab: the extension (0.0.10+) closes it by session id
        let file = writeCommand("close", a, extra: extra)
        agents[i].detail = "closing…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let j = self.agents.firstIndex(where: { $0.id == a.id }) else { return }
            // gone, or a chat tab whose close the extension picked up (its process can outlive the tab)
            let claimed = a.panel && file.map { !FileManager.default.fileExists(atPath: $0.path) } == true
            if kill(pid_t(a.claudePid), 0) != 0 || claimed {
                self.agents.remove(at: j)
                if self.openId == a.id { self.openId = nil }
            } else if self.agents[j].detail == "closing…" {
                self.agents[j].detail = "couldn't close it · close the tab in \(a.appName)"
            }
        }
    }

    @discardableResult
    private func writeCommand(_ action: String, _ a: Agent, extra: [String: Any] = [:]) -> URL? {
        try? FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        let json: [String: Any] = ["action": action, "claude_pid": a.claudePid, "claude_ppid": a.claudePpid,
                                   "session_id": a.id, "cwd": a.cwd, "panel": a.panel,
                                   "at": Date().timeIntervalSince1970].merging(extra) { x, _ in x }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 1000...9999))"
        let tmp = commandsDir.appendingPathComponent(name + ".tmp")
        try? data.write(to: tmp)
        let dest = commandsDir.appendingPathComponent(name + ".json")
        try? FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func bringVSCodeForward() { bringAppForward("com.microsoft.VSCode") }

    private func bringAppForward(_ bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    /// Every few seconds: drop closed sessions, notice killed ones, sweep stale command files.
    func tidy() {
        let now = Date()
        for i in agents.indices where agents[i].endedAt == nil && agents[i].claudePid > 0 && agents[i].asks.isEmpty {
            if kill(pid_t(agents[i].claudePid), 0) != 0 {
                agents[i].mood = .done
                agents[i].detail = "session closed"
                agents[i].endedAt = now
            }
        }
        agents.removeAll { a in
            if let end = a.endedAt { return now.timeIntervalSince(end) > 6 }
            return a.claudePid == 0 && now.timeIntervalSince(a.lastSeen) > 7200
        }
        tails = tails.filter { id, _ in agents.contains { $0.id == id } }
        if let id = openId, !agents.contains(where: { $0.id == id }) { openId = nil }
        if let files = try? FileManager.default.contentsOfDirectory(at: commandsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files {
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(mod) > 20 { try? FileManager.default.removeItem(at: f) }
            }
        }
    }
}

// MARK: - Test endpoints (AGENT_HUDDLE_TEST=1 only)

extension Store {
    /// "state": every agent with its mood and asks. "answer": clicks a button on an ask, as you would:
    /// {session_id, index (which ask, default 0), decision "allow"/"deny"/"vscode", always (suggestion index),
    ///  answers {question: label}}.
    func testCommand(_ cmd: String, _ body: [String: Any]) -> String {
        if cmd == "answer" {
            guard let sid = body["session_id"] as? String, let a = agents.first(where: { $0.id == sid }) else { return #"{"ok":false,"why":"no agent"}"# }
            let n = body["index"] as? Int ?? 0
            guard n < a.asks.count else { return #"{"ok":false,"why":"no ask"}"# }
            let ask = a.asks[n]
            if let ans = body["answers"] as? [String: String] { answer(ask.id, answers: ans) }
            else {
                let d = body["decision"] as? String
                let always = (body["always"] as? Int).flatMap { $0 < ask.suggestions.count ? ask.suggestions[$0] : nil }
                answer(ask.id, d == "vscode" ? nil : d, always: always)
            }
            return #"{"ok":true}"#
        }
        let list: [[String: Any]] = agents.map { a in
            ["id": a.id, "name": a.name, "seen": a.seen, "mood": "\(a.mood)", "detail": a.detail, "helpers": a.helpers,
             "ended": a.endedAt != nil, "panel": a.panel, "pid": a.claudePid,
             "asks": a.asks.map { ["text": $0.text, "full": ([$0.text] + $0.code.map(\.text)).joined(separator: "\n"), "questions": $0.questions.count, "suggestions": $0.suggestions.map { suggestionLabel($0, cwd: a.cwd) }] }]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["agents": list, "held": held.count, "order": shown.map(\.id)])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Live transcript (steps + actions)

let stepPattern = try! NSRegularExpression(pattern: #"(?m)^[ \t>*_]*[▰▱]{2,}\s*(\d+)\s*/\s*(\d+)\s*·\s*([^\n]+)"#)

extension Store {
    /// Every second: read whatever each agent's transcript gained since last time.
    func pollTranscripts() {
        for i in agents.indices {
            guard let path = agents[i].transcript, agents[i].endedAt == nil || openId == agents[i].id,
                  let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            let id = agents[i].id
            var tail = tails[id] ?? Tail()
            let size = (try? fh.seekToEnd()) ?? 0
            if !tail.started {  // first look: only the last 1.5 MB, starting at a line break
                tail.started = true
                tail.offset = size > 1_500_000 ? size - 1_500_000 : 0
                tail.skipFirst = tail.offset > 0
            }
            if size < tail.offset { tail = Tail(offset: 0, rest: Data(), started: true, skipFirst: false) }
            guard size > tail.offset else { tails[id] = tail; continue }
            try? fh.seek(toOffset: tail.offset)
            let data = fh.readData(ofLength: Int(min(size - tail.offset, 4_000_000)))
            tail.offset += UInt64(data.count)
            var lines = (tail.rest + data).split(separator: 0x0a, omittingEmptySubsequences: false)
            tail.rest = Data(lines.removeLast())
            if tail.skipFirst, !lines.isEmpty { lines.removeFirst(); tail.skipFirst = false }
            tails[id] = tail
            var a = agents[i]
            var changed = false
            for line in lines where apply(Data(line), to: &a) { changed = true; a.seen = true }
            if changed { agents[i] = a }
        }
    }

    private func apply(_ line: Data, to a: inout Agent) -> Bool {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        // VS Code's tab title: auto ("ai-title") or renamed by you ("custom-title"); a skill name still wins
        for (kind, key, rank) in [("ai-title", "aiTitle", 1), ("custom-title", "customTitle", 2)] where row["type"] as? String == kind {
            guard let t = row[key] as? String, !t.isEmpty, rank >= a.titleRank, a.name != t || a.titleRank != rank else { return false }
            a.name = t
            a.titleRank = rank
            return true
        }
        guard let msg = row["message"] as? [String: Any] else { return false }
        // A new request from you clears a finished progress bar ("6/6 · Done"); an unfinished one stays
        // (a "go" or an answer mid-job carries on the same job).
        if row["type"] as? String == "user", isPrompt(row, msg["content"]), let s = a.step, s.n >= s.total {
            a.step = nil
            return true
        }
        guard let parts = msg["content"] as? [[String: Any]] else { return false }
        var changed = false
        for part in parts {
            switch part["type"] as? String {
            case "text":
                let text = part["text"] as? String ?? ""
                let ns = text as NSString
                // only Claude's own lines: user rows carry CLAUDE.md, whose example bar ends "6/6 · Done"
                if row["type"] as? String == "assistant",
                   let m = stepPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).last {
                    let label = ns.substring(with: m.range(at: 3)).replacingOccurrences(of: "✅", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    a.step = Step(n: Int(ns.substring(with: m.range(at: 1))) ?? 0,
                                  total: Int(ns.substring(with: m.range(at: 2))) ?? 0, label: label)
                    changed = true
                }
            case "tool_use":
                let id = part["id"] as? String ?? UUID().uuidString
                useKeys[id] = toolKey(part["name"] as? String ?? "", part["input"])  // removed again by its result
                if useKeys.count > 400 { useKeys.removeAll() }
                a.actions.append(makeAction(id, part["name"] as? String ?? "tool", part["input"] as? [String: Any] ?? [:], cwd: a.cwd))
                if a.actions.count > 40 { a.actions.removeFirst(a.actions.count - 40) }
                changed = true
            case "tool_result":
                if let id = part["tool_use_id"] as? String, let key = useKeys.removeValue(forKey: id) {
                    let ids = a.asks.filter { $0.key == key }.map(\.id)
                    if !ids.isEmpty { settle(&a, ids); changed = true }
                }
                guard let id = part["tool_use_id"] as? String, let k = a.actions.lastIndex(where: { $0.id == id }) else { continue }
                a.actions[k].result = clip(resultText(part["content"]), 20000)
                a.actions[k].state = part["is_error"] as? Bool == true ? .failed : .done
                changed = true
            default:
                break
            }
        }
        return changed
    }
}

/// A user row you typed (not a tool result, skill text, task notification or compaction summary).
func isPrompt(_ row: [String: Any], _ content: Any?) -> Bool {
    if row["isMeta"] as? Bool == true || row["isCompactSummary"] as? Bool == true { return false }
    var text = content as? String ?? ""
    if let parts = content as? [[String: Any]] {
        if parts.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
        text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !t.isEmpty && !t.hasPrefix("<")
}

func resultText(_ c: Any?) -> String {
    if let s = c as? String { return s }
    if let arr = c as? [[String: Any]] { return arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
    return ""
}

/// A path as short as it can go: relative to the session's folder, else with ~ for your home folder.
func rel(_ p: String, _ cwd: String = "") -> String {
    var p = p
    if !cwd.isEmpty { p = p.replacingOccurrences(of: cwd.hasSuffix("/") ? cwd : cwd + "/", with: "") }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return p.replacingOccurrences(of: home + "/", with: "~/")
}

func lines(_ s: String, _ kind: CodeLine.Kind, max: Int = 60) -> [CodeLine] {
    s.split(separator: "\n", omittingEmptySubsequences: false).prefix(max).map { CodeLine(text: String($0), kind: kind) }
}

func makeAction(_ id: String, _ tool: String, _ input: [String: Any], cwd: String = "") -> Action {
    let path = input["file_path"] as? String ?? ""
    switch tool {
    case "Read":
        return Action(id: id, tool: tool, title: base(path), path: rel(path, cwd), lead: [])
    case "Edit":
        let lead = lines(input["old_string"] as? String ?? "", .del, max: 30) + lines(input["new_string"] as? String ?? "", .add, max: 30)
        return Action(id: id, tool: tool, title: base(path), path: rel(path, cwd), lead: lead)
    case "MultiEdit":
        let edits = input["edits"] as? [[String: Any]] ?? []
        let lead = edits.prefix(4).flatMap { lines($0["old_string"] as? String ?? "", .del, max: 12) + lines($0["new_string"] as? String ?? "", .add, max: 12) }
        return Action(id: id, tool: tool, title: base(path), path: rel(path, cwd), lead: lead)
    case "Write":
        return Action(id: id, tool: tool, title: base(path), path: rel(path, cwd), lead: lines(input["content"] as? String ?? "", .add))
    case "Bash":
        return Action(id: id, tool: tool, title: clip(input["description"] as? String ?? "Command", 40),
                      path: input["description"] as? String ?? "",
                      lead: lines("$ " + (input["command"] as? String ?? ""), .cmd, max: 12))
    case "Grep", "Glob":
        return Action(id: id, tool: tool, title: clip(input["pattern"] as? String ?? "search", 40), path: rel(input["path"] as? String ?? "", cwd), lead: [])
    case "Skill":
        return Action(id: id, tool: tool, title: input["skill"] as? String ?? "skill", path: "Skill",
                      lead: lines(input["args"] as? String ?? "", .dim, max: 8))
    case "Agent", "Task":
        return Action(id: id, tool: tool, title: clip(input["description"] as? String ?? "Helper", 40), path: "Helper agent",
                      lead: lines(input["prompt"] as? String ?? "", .dim, max: 20))
    case "WebFetch", "WebSearch":
        return Action(id: id, tool: tool, title: tool == "WebFetch" ? "Fetch page" : "Web search",
                      path: clip(input["url"] as? String ?? input["query"] as? String ?? "", 60), lead: [])
    default:
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        let short = tool.hasPrefix("mcp__") ? mcpName(tool) : tool
        return Action(id: id, tool: tool, title: short, path: tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").dropFirst().first ?? "") : "",
                      lead: lines(String(decoding: data, as: UTF8.self), .dim, max: 20))
    }
}

func icon(_ tool: String) -> String {
    switch tool {
    case "Read": return "doc.text"
    case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
    case "Bash": return "apple.terminal"
    case "Grep", "Glob": return "magnifyingglass"
    case "Skill": return "sparkles"
    case "Agent", "Task": return "person.2"
    case "WebFetch", "WebSearch": return "globe"
    default: return tool.contains("firecrawl") || tool.contains("chrome") ? "globe" : "wrench.and.screwdriver"
    }
}

// MARK: - Naming and descriptions

/// "Review · auth flow" when the prompt starts with a slash command (/review auth flow); nil otherwise.
/// A command name beats the chat's auto title, since it says what the session is for.
func skillName(_ prompt: String) -> String? {
    let p = firstLine(prompt)
    guard p.hasPrefix("/"), let m = p.range(of: #"^/([A-Za-z0-9][A-Za-z0-9:_-]*)"#, options: .regularExpression) else { return nil }
    let cmd = String(p[m].dropFirst()).split(separator: ":").last.map(String.init) ?? ""
    let label = cmd.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    let rest = p[m.upperBound...].trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? label : "\(label) · " + clip(rest.split(separator: " ").prefix(4).joined(separator: " "), 24)
}

/// The first line you actually typed (skips injected blocks like <browser_instruction>…).
func firstLine(_ prompt: String) -> String {
    let lines = prompt.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.first(where: { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("#") }) ?? (lines.first ?? prompt)
}

func nameFor(_ prompt: String) -> String {
    clip(firstLine(prompt).split(separator: " ").prefix(5).joined(separator: " "), 30)
}

/// mcp__github__create_issue → "github · create issue" (server, then the tool with spaces).
func mcpName(_ t: String) -> String {
    let parts = t.components(separatedBy: "__").dropFirst()
    guard let server = parts.first else { return t }
    let tool = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    let srv = server.replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
    return tool.isEmpty ? srv : "\(srv) · \(tool)"
}

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

func base(_ path: Any?) -> String { ((path as? String) ?? "").split(separator: "/").last.map(String.init) ?? "a file" }

func toolName(_ e: [String: Any]) -> String {
    let t = e["tool_name"] as? String ?? "tool"
    if t.hasPrefix("mcp__") { return mcpName(t) }
    return t
}

/// Short status line for PreToolUse.
func describe(_ e: [String: Any]) -> String {
    let input = e["tool_input"] as? [String: Any] ?? [:]
    switch e["tool_name"] as? String ?? "" {
    case "Bash": return clip((input["description"] as? String) ?? (input["command"] as? String) ?? "running a command", 60)
    case "Edit", "Write", "MultiEdit", "NotebookEdit": return "editing \(base(input["file_path"]))"
    case "Read": return "reading \(base(input["file_path"]))"
    case "Grep", "Glob": return "searching files"
    case "Skill": return "running \(input["skill"] as? String ?? "a skill")"
    case "Agent", "Task": return "helper: " + clip(input["description"] as? String ?? "working", 40)
    case "WebFetch", "WebSearch": return "browsing the web"
    default:
        let t = e["tool_name"] as? String ?? ""
        if t.contains("firecrawl") || t.contains("chrome") { return "browsing the web" }
        return "using \(toolName(e))"
    }
}

/// Title line of the permission card.
func askText(_ e: [String: Any]) -> String {
    let input = e["tool_input"] as? [String: Any] ?? [:]
    let tool = e["tool_name"] as? String ?? "tool"
    switch tool {
    case "Bash": return clip(input["description"] as? String ?? "Run a command", 120)
    case "Edit", "Write", "MultiEdit", "NotebookEdit", "Read":
        let path = rel(input["file_path"] as? String ?? input["notebook_path"] as? String ?? "", e["cwd"] as? String ?? "")
        return "\(tool) · \(clip(path, 200))"
    case "WebFetch": return "Fetch · " + clip(input["url"] as? String ?? "", 200)
    default: return toolName(e)
    }
}

/// Everything the card shows under the title: the whole command, the edit as a red/green diff, or the input.
func askCode(_ e: [String: Any]) -> [CodeLine] {
    let input = e["tool_input"] as? [String: Any] ?? [:]
    let tool = e["tool_name"] as? String ?? "tool"
    switch tool {
    case "Bash": return lines("$ " + (input["command"] as? String ?? ""), .cmd, max: 400)
    case "Edit", "MultiEdit", "Write": return makeAction("", tool, input, cwd: e["cwd"] as? String ?? "").lead
    case "NotebookEdit": return lines(input["new_source"] as? String ?? "", .add, max: 60)
    case "Read": return []
    case "WebFetch": return lines(input["prompt"] as? String ?? "", .dim, max: 20)
    default:
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return lines(String(decoding: data, as: UTF8.self), .dim, max: 60)
    }
}

// MARK: - Local server (127.0.0.1 only, bearer token)

final class Server {
    let store: Store
    let token = UUID().uuidString
    var listener: NWListener!

    init(store: Store) { self.store = store }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.read(c, Data())
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self, let port = self.listener.port?.rawValue { self.writeServerFile(Int(port)) }
        }
        listener.start(queue: .main)
    }

    private func writeServerFile(_ port: Int) {
        // The folder and the token file are only ever readable by you: the file is created 0600 from the start
        // (in a temp file, then moved into place), never written first and locked down after.
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        chmod(stateDir.path, 0o700)
        let json = "{\"port\":\(port),\"token\":\"\(token)\",\"pid\":\(getpid())}"
        let tmp = stateDir.appendingPathComponent(".server.json.tmp")
        unlink(tmp.path)
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        _ = json.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        rename(tmp.path, serverFile.path)
    }

    private func read(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = soFar
            if let data { buf.append(data) }
            if let (head, body) = Server.parse(buf) { self.respond(c, head, body); return }
            if done || err != nil || buf.count > 4_000_000 { c.cancel(); return }
            self.read(c, buf)
        }
    }

    static func parse(_ buf: Data) -> (String, Data)? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var length = 0
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = buf[end.upperBound...]
        return body.count >= length ? (head, Data(body.prefix(length))) : nil
    }

    private func respond(_ c: NWConnection, _ head: String, _ body: Data) {
        let lower = head.lowercased()
        if testMode, lower.hasPrefix("post /test/"), lower.contains("authorization: bearer \(token.lowercased())") {
            Server.reply(c, store.testCommand(lower.hasPrefix("post /test/answer ") ? "answer" : "state",
                                              (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]))
            return
        }
        guard lower.hasPrefix("post /event "), lower.contains("authorization: bearer \(token.lowercased())"),
              let e = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { Server.reply(c, "{}", status: "403 Forbidden"); return }
        guard let askId = store.handle(e, conn: c) else { Server.reply(c, "{}"); return }
        // Held open for your click. If the hook goes away first (answered in VS Code / timeout), forget it.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, err in
            if done || err != nil { self?.store.dropAsk(askId) }
        }
    }

    static func reply(_ c: NWConnection, _ body: String, status: String = "200 OK") {
        let text = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(text.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - The blob

struct Pose { var lift = 0.0, sx = 1.0, sy = 1.0, rot = 0.0, look = 0.0 }

func pose(_ mood: Mood, _ t: Double) -> Pose {
    func hop(_ speed: Double, _ height: Double) -> Pose {
        let ph = (t * speed).truncatingRemainder(dividingBy: 1)
        let ground = max(0, 1 - min(ph, 1 - ph) * 7)  // 1 right at landing
        var p = Pose()
        p.lift = sin(ph * .pi) * height
        p.sx = 1 + 0.16 * ground
        p.sy = 1 - 0.16 * ground + 0.05 * (1 - ground)
        return p
    }
    switch mood {
    case .working:
        var p = hop(2.0, 8)
        p.look = sin(t * 1.3) * 1.8
        return p
    case .needsYou:
        var p = hop(2.8, 11)
        p.rot = sin(t * 9) * 7
        return p
    case .idle, .done:
        let b = sin(t * 1.6) * 0.035
        return Pose(lift: 0, sx: 1 + b, sy: 1 - b)
    }
}

// Cursor bots: each agent is a terminal block cursor with pixel eyes and two little legs.
// Working = steps and types (code glyphs drift out), needs you = jumps with a lime outline + "?",
// plan ready = "!" badge, idle = classic cursor blink, done = hollow outline, "– –" eyes, z.
let ink = rgb(0x0b0b0b)
let glyphs = [">_", "{}", "01", "</>", "$", "=>", "fn", "[]"]

// Drawn with one Canvas per frame (not ~15 stacked SwiftUI shapes): same look, a fraction of the CPU.
// Frame rate by mood: moving bots 20 fps, idle/closed ones 5 fps (enough for the blink). All bots share one
// clock, so the window redraws once per tick instead of once per bot.
let clockStart = Date(timeIntervalSinceReferenceDate: 0)
/// false while the panel can't be seen (covered, screen off): bots stop animating, so no CPU is spent.
final class Visibility: ObservableObject { @Published var on = true }
let visibility = Visibility()
struct Blob: View {
    let mood: Mood
    let color: Color
    let seed: Double
    var size: CGFloat = 52
    @ObservedObject private var vis = visibility

    var body: some View {
        TimelineView(.periodic(from: clockStart, by: !vis.on ? 3600 : mood == .working || mood == .needsYou ? 1.0 / 20 : 1.0 / 5)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate + seed
            // bigger than the bot's 52×52 box so the hop, "?" badge and z aren't clipped; the box sits in the middle
            Canvas { ctx, _ in ctx.translateBy(x: 10, y: 14); draw(&ctx, t, pose(mood, t)) }
                .frame(width: 72, height: 80)
        }
        .frame(width: 52, height: 52)
        .scaleEffect(size / 52)
        .frame(width: size, height: size)
        .opacity(mood == .done ? 0.55 : 1)
    }

    func draw(_ ctx: inout GraphicsContext, _ t: Double, _ p: Pose) {
        let alert = mood == .needsYou
        // idle: the cursor blinks (solid ↔ outline) once a second; done: always outline
        let hollow = mood == .done || (mood == .idle && t.truncatingRemainder(dividingBy: 1.1) > 0.75)
        let step = mood == .working ? sin(t * 10) : 0
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
        }
        // shadow on the ground
        let sw = 24 * (1 - p.lift / 40)
        ctx.fill(Path(ellipseIn: CGRect(x: 26 - sw / 2, y: 47.25, width: sw, height: 3.5)), with: .color(.black.opacity(0.3)))
        if mood == .working {  // typed characters drifting up-right and fading
            for k in 0..<2 {
                let ph = (t * 0.9 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let g = glyphs[Int(t * 0.9 + Double(k) * 0.5 + seed) % glyphs.count]
                ctx.draw(Text(g).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(lime.opacity(0.9 * (1 - ph))),
                         at: CGPoint(x: 43 + ph * 6, y: 24 - ph * 16))
            }
        }
        // the bot: offset (hop), then rotate + squash around its bottom edge
        var b = ctx
        b.translateBy(x: 0, y: -1 - p.lift)
        b.translateBy(x: 26, y: 45)
        b.rotate(by: .degrees(p.rot * 0.6))
        b.scaleBy(x: p.sx, y: p.sy)
        b.translateBy(x: -26, y: -45)
        // legs
        b.fill(rr(19, 41 + (step > 0 ? -1.5 : 0), 3, 6, 1.5), with: .color(color))
        b.fill(rr(30, 41 + (step < 0 ? -1.5 : 0), 3, 6, 1.5), with: .color(color))
        // the cursor block
        let block = rr(13, 10, 26, 32, 3.5)
        if hollow { b.stroke(block, with: .color(color), lineWidth: 2.2) } else { b.fill(block, with: .color(color)) }
        if alert { b.stroke(rr(10, 7, 32, 38, 5), with: .color(lime.opacity(0.6 + 0.4 * sin(t * 8))), lineWidth: 2) }
        // eyes
        let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.13
        let ew: CGFloat, eh: CGFloat
        switch mood {
        case .done: (ew, eh) = (5.5, 1.8)  // asleep – –
        case .needsYou: (ew, eh) = (5, blink ? 1 : 6.5)  // wide
        default: (ew, eh) = (4, blink ? 1 : 5)
        }
        let eye = Color(white: hollow ? 1 : 0.043).opacity(hollow ? 0.75 : 1)
        for side in [-1.0, 1.0] {
            let cx = 26 + p.look + side * (ew / 2 + 3)
            b.fill(rr(cx - ew / 2, 22 - eh / 2, ew, eh, mood == .done ? 0 : 1), with: .color(eye))
        }
        // underscore "prompt" line at the bottom of the block while working
        if mood == .working, t.truncatingRemainder(dividingBy: 0.6) < 0.35 {
            b.fill(Path(CGRect(x: 18.5, y: 34, width: 9, height: 2)), with: .color(ink.opacity(0.85)))
        }
        if mood == .done {
            let z = (t * 0.6).truncatingRemainder(dividingBy: 1)
            ctx.draw(Text("z").font(.system(size: 9 + z * 4, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.7 * (1 - z))),
                     at: CGPoint(x: 43 + z * 5, y: 14 - z * 10))
        }
        if alert {
            let y = 9 - p.lift
            ctx.fill(rr(36.5, y - 7.5, 15, 15, 3), with: .color(lime))
            ctx.draw(Text("?").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundColor(.black), at: CGPoint(x: 44, y: y))
        }
    }
}

// MARK: - Panel content

struct DragHandle: NSViewRepresentable {
    final class V: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct Pill: View {
    let title: String
    var filled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .foregroundColor(filled ? .black : .white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(filled ? lime : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct Row: View {
    let a: Agent
    @ObservedObject var store: Store
    @State private var armed = false  // × clicked once; a second click within 3 s closes

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Blob(mood: a.mood, color: a.color, seed: a.seed)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(a.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        if a.helpers > 0 {
                            Text("+\(a.helpers)").font(.system(size: 9, weight: .bold)).foregroundColor(.black)
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(a.color))
                        }
                    }
                    Text(a.detail).font(.system(size: 11)).foregroundColor(.white.opacity(0.6)).lineLimit(2)
                    if let s = a.step { StepBar(step: s, color: a.color).padding(.top, 3) }
                }
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    IconButton(symbol: "arrow.up.forward.app") { store.focus(a) }.help("Jump to this agent in \(a.appName)")
                    if armed {
                        Button { armed = false; store.close(a) } label: {
                            Text("Close").font(.system(size: 9.5, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(rgb(0xe5484d)))
                        }
                        .buttonStyle(.plain).help(a.otherApp || a.desktop ? "Click again to remove it from the list" : "Click again to close this session in VS Code")
                    } else {
                        IconButton(symbol: "xmark") {
                            armed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
                        }
                        .help(a.endedAt == nil ? "Close this session (asks once more)" : "Remove from the list")
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.pickedAction = nil; store.openId = a.id }
            .help("Click to watch this agent live")
            if let ask = a.asks.first, !ask.questions.isEmpty {
                QuestionCard(ask: ask, store: store, more: a.asks.count - 1, appName: a.appName) { store.answer(ask.id, nil); store.focus(a) }
                    .id(ask.id)
            } else if let ask = a.asks.first {
                AskBody(ask: ask)
                HStack(spacing: 6) {
                    Pill(title: "Allow", filled: true) { store.answer(ask.id, "allow") }
                    Pill(title: "Deny") { store.answer(ask.id, "deny") }
                    Pill(title: "In " + a.appName) { store.answer(ask.id, nil); store.focus(a) }
                    if a.asks.count > 1 {
                        Text("+\(a.asks.count - 1) more").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                    }
                }
                ForEach(Array(ask.suggestions.enumerated()), id: \.offset) { _, s in
                    Pill(title: suggestionLabel(s, cwd: a.cwd)) { store.answer(ask.id, "allow", always: s) }
                        .help("Allow, and don't ask again for this")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(a.mood == .needsYou ? 0.08 : 0.04)))
    }
}

/// AskUserQuestion in the widget: tap options (several when multi-select), then Send.
struct QuestionCard: View {
    let ask: Ask
    @ObservedObject var store: Store
    let more: Int
    var appName = "VS Code"
    let inVSCode: () -> Void
    @State private var picked: [Int: [String]] = [:]
    @State private var page = 0  // one question at a time; tabs + Back to move around

    var ready: Bool { ask.questions.allSatisfy { !(picked[$0.id] ?? []).isEmpty } }
    var q: Question { ask.questions[min(page, ask.questions.count - 1)] }
    var last: Bool { page >= ask.questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if ask.questions.count > 1 {  // tabs: lime = answered, outlined = this one
                HStack(spacing: 4) {
                    ForEach(ask.questions) { x in
                        let done = !(picked[x.id] ?? []).isEmpty
                        Button { page = x.id } label: {
                            Text(x.header.isEmpty ? "Q\(x.id + 1)" : x.header.uppercased())
                                .font(.system(size: 8.5, weight: .heavy)).lineLimit(1)
                                .foregroundColor(done ? .black : .white.opacity(x.id == page ? 1 : 0.55))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(done ? lime : Color.white.opacity(x.id == page ? 0.18 : 0.07)))
                                .overlay(Capsule().stroke(x.id == page ? lime : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                    Text("\(page + 1) of \(ask.questions.count)").font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                }
            } else if !q.header.isEmpty {
                Text(q.header.uppercased()).font(.system(size: 8.5, weight: .heavy)).foregroundColor(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1.5).background(Capsule().fill(lime))
            }
            Text(q.text).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            if q.multi { Text("pick any, then Next").font(.system(size: 9)).foregroundColor(.white.opacity(0.45)) }
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in option(q, o.label, o.desc) }
            HStack(spacing: 6) {
                if page > 0 { Pill(title: "‹ Back") { page -= 1 } }
                if last {
                    Pill(title: "Send", filled: ready) {
                        guard ready else {  // jump to the first unanswered question
                            if let x = ask.questions.first(where: { (picked[$0.id] ?? []).isEmpty }) { page = x.id }
                            return
                        }
                        var answers: [String: String] = [:]
                        for x in ask.questions { answers[x.text] = (picked[x.id] ?? []).joined(separator: ", ") }
                        store.answer(ask.id, answers: answers)
                    }
                    .opacity(ready ? 1 : 0.5)
                } else {
                    Pill(title: "Next ›", filled: !(picked[q.id] ?? []).isEmpty) { page += 1 }
                }
                Pill(title: "Type in \(appName)", action: inVSCode)
                if more > 0 { Text("+\(more) more").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)) }
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
        .animation(.easeOut(duration: 0.15), value: page)
    }

    func option(_ q: Question, _ label: String, _ desc: String) -> some View {
        let on = (picked[q.id] ?? []).contains(label)
        return Button {
            var cur = picked[q.id] ?? []
            if q.multi { if on { cur.removeAll { $0 == label } } else { cur.append(label) } } else { cur = [label] }
            picked[q.id] = cur
            if !q.multi && !last {  // single choice: move on by itself after a beat
                let at = q.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if page == at { page += 1 } }
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: on ? (q.multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (q.multi ? "square" : "circle"))
                    .font(.system(size: 11)).foregroundColor(on ? lime : .white.opacity(0.4)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if !desc.isEmpty {
                        Text(desc).font(.system(size: 9.5)).foregroundColor(.white.opacity(0.5)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? lime.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? lime.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Permission card body: the title, then the whole command / diff, scrolling once it gets long.
struct AskBody: View {
    let ask: Ask
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ask.text).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white.opacity(0.9)).lineLimit(2)
            if !ask.code.isEmpty {
                ScrollView(.vertical, showsIndicators: height >= 170) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(ask.code.enumerated()), id: \.offset) { _, l in codeLine(l) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }

    /// Wrapped lines at ~42 monospaced characters each; past 170 pt it scrolls.
    var height: CGFloat {
        let rows = ask.code.reduce(0) { $0 + max(1, Int(ceil(Double($1.text.count + 2) / 42))) }
        return min(170, CGFloat(rows) * 13.5 + 2)
    }

    func codeLine(_ l: CodeLine) -> some View {
        let color: Color = l.kind == .add ? rgb(0x8ee59b) : l.kind == .del ? rgb(0xff8a8a) : l.kind == .dim ? .white.opacity(0.6) : .white.opacity(0.9)
        let bg: Color = l.kind == .add ? rgb(0x2ea043).opacity(0.15) : l.kind == .del ? rgb(0xf85149).opacity(0.15) : .clear
        let mark = l.kind == .add ? "+ " : l.kind == .del ? "- " : ""
        return Text(mark + (l.text.isEmpty ? " " : l.text)).font(.system(size: 10.5, design: .monospaced)).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).background(bg)
    }
}

struct StepBar: View {
    let step: Step
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(step.n)/\(step.total)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(lime)
                Text(step.label).font(.system(size: 10)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(lime).frame(width: max(4, g.size.width * step.fraction))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.4), value: step.fraction)
        }
    }
}

/// Spinner / tick / cross in front of each action.
struct StateIcon: View {
    let state: ActState
    var body: some View {
        switch state {
        case .running:
            TimelineView(.animation) { tl in
                Circle().trim(from: 0, to: 0.7).stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate * 360))
            }
            .frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.white.opacity(0.35))
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(rgb(0xff6b6b))
        }
    }
}

/// The big live view: blob + step + recent actions on the left, the picked action's code on the right.
struct Detail: View {
    let a: Agent
    @ObservedObject var store: Store

    var shown: Action? {
        if let id = store.pickedAction, let x = a.actions.first(where: { $0.id == id }) { return x }
        return a.actions.last
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            left.frame(width: 178, alignment: .leading)
            CodePane(action: shown)
        }
        .padding(10)
        .frame(width: 660, height: 360)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    var left: some View {
        VStack(alignment: .leading, spacing: 6) {
            Blob(mood: a.mood, color: a.color, seed: a.seed, size: 76).padding(.leading, -4)
            Text(a.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white).lineLimit(2)
            Text(a.detail).font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).lineLimit(2)
            if let s = a.step { StepBar(step: s, color: a.color) }
            if let ask = a.asks.first, !ask.questions.isEmpty {
                Pill(title: "Answer question", filled: true) { store.openId = nil }
            } else if let ask = a.asks.first {
                Text(ask.text).font(.system(size: 9.5, design: .monospaced)).foregroundColor(.white.opacity(0.85)).lineLimit(3)
                HStack(spacing: 4) {
                    Pill(title: "Allow", filled: true) { store.answer(ask.id, "allow") }
                    Pill(title: "Deny") { store.answer(ask.id, "deny") }
                }
                ForEach(Array(ask.suggestions.enumerated()), id: \.offset) { _, s in
                    Pill(title: suggestionLabel(s, cwd: a.cwd)) { store.answer(ask.id, "allow", always: s) }
                }
            }
            Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)
            ForEach(a.actions.suffix(6).reversed()) { act in
                Button { store.pickedAction = act.id } label: {
                    HStack(spacing: 7) {
                        StateIcon(state: act.state)
                        Image(systemName: icon(act.tool)).font(.system(size: 10)).foregroundColor(.white.opacity(0.5)).frame(width: 12)
                        Text(act.title).font(.system(size: 11.5, weight: act.id == shown?.id ? .semibold : .regular))
                            .foregroundColor(.white.opacity(act.id == shown?.id ? 1 : act.state == .running ? 0.9 : 0.5)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CodePane: View {
    let action: Action?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let a = action {
                    HStack(spacing: 5) {
                        Image(systemName: icon(a.tool)).font(.system(size: 10)).foregroundColor(lime)
                        Text(a.tool == "Bash" ? "Terminal" : a.title).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                    Spacer()
                    Text(a.path).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.35)).lineLimit(1).truncationMode(.head)
                } else {
                    Text("Waiting for the first action…").font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                }
            }
            .padding(8)
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(content(action).enumerated()), id: \.offset) { i, line in
                            row(i, line)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: action?.result.count ?? 0) { _ in
                    if action?.tool == "Bash" { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.45)))
    }

    /// What to show: the call (diff / command) then the result.
    func content(_ a: Action?) -> [CodeLine] {
        guard let a else { return [] }
        var out = a.lead
        let result = a.result.replacingOccurrences(of: "→", with: "  ")
        switch a.tool {
        case "Edit", "MultiEdit", "Write":
            if a.state == .failed { out += lines(result, .del, max: 10) }
        case "Bash":
            let all = result.split(separator: "\n", omittingEmptySubsequences: false)
            out += all.suffix(80).map { CodeLine(text: String($0), kind: a.state == .failed ? .del : .plain) }
            if a.state == .running { out.append(CodeLine(text: "…", kind: .dim)) }
        default:
            out += lines(result, .plain, max: 120)
        }
        return out
    }

    func row(_ i: Int, _ line: CodeLine) -> some View {
        let color: Color = {
            switch line.kind {
            case .add: return rgb(0x8ee59b)
            case .del: return rgb(0xff8a8a)
            case .cmd: return lime
            case .dim: return .white.opacity(0.45)
            case .plain: return .white.opacity(0.85)
            }
        }()
        let bg: Color = line.kind == .add ? rgb(0x2ea043).opacity(0.15) : line.kind == .del ? rgb(0xf85149).opacity(0.15) : .clear
        let mark = line.kind == .add ? "+ " : line.kind == .del ? "- " : ""
        return Text(mark + (line.text.isEmpty ? " " : clip(line.text, line.kind == .cmd ? 600 : 220)))
            .font(.system(size: 11, design: .monospaced)).foregroundColor(color)
            .lineLimit(line.kind == .cmd ? 6 : 1).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).background(bg)
    }
}

struct IconButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

struct SizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct RowsKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct Root: View {
    @State private var rowsHeight: CGFloat = 0
    @ObservedObject var store: Store
    let onSize: (CGSize) -> Void

    var body: some View {
        Group {
            if store.collapsed { collapsed } else { expanded }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.05).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { onSize($0) }
    }

    var header: some View {
        HStack(spacing: 6) {
            if open != nil {
                IconButton(symbol: "chevron.left") { store.openId = nil }.help("Back to all agents")
                ForEach(store.shown) { a in  // switch agents without going back
                    Blob(mood: a.mood, color: a.color, seed: a.seed, size: 24)
                        .opacity(a.id == store.openId ? 1 : 0.55)
                        .onTapGesture { store.pickedAction = nil; store.openId = a.id }
                }
            } else {
                Circle().fill(lime).frame(width: 6, height: 6)
                Text("Agent Huddle").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                if !store.shown.isEmpty {
                    Text("\(store.shown.count)").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.45))
                }
            }
            Spacer()
            if let a = open { IconButton(symbol: "arrow.up.forward.app") { store.focus(a) }.help("Jump to this agent in \(a.appName)") }
            IconButton(symbol: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { store.muted.toggle() }
            IconButton(symbol: "chevron.up") { store.collapsed = true }
            IconButton(symbol: "xmark") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 6)
        .background(DragHandle())
    }

    var open: Agent? { store.openId.flatMap { id in store.agents.first { $0.id == id } } }

    @ViewBuilder var expanded: some View {
        if let a = open {
            VStack(spacing: 6) {
                header
                Detail(a: a, store: store)
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
        } else {
            list
        }
    }

    var list: some View {
        VStack(spacing: 6) {
            header
            if store.shown.isEmpty {
                HStack(spacing: 8) {
                    Blob(mood: .idle, color: Color(white: 0.5), seed: 0)
                    Text("No agents running").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
            // Rows scroll once they'd run past ~85% of the screen; the panel stays content-sized below that.
            ScrollView(.vertical, showsIndicators: rowsHeight > maxRows) {
                VStack(spacing: 6) { ForEach(store.shown) { a in Row(a: a, store: store) } }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { rowsHeight = g.size.height }
                            .onChange(of: g.size.height) { rowsHeight = $0 }
                    })
            }
            .frame(height: min(max(rowsHeight, 1), maxRows))
        }
        .padding(.horizontal, 6).padding(.bottom, 8)
        .frame(width: 300)
    }

    var maxRows: CGFloat { ((NSScreen.main?.visibleFrame.height ?? 900) * 0.85) - 60 }

    var collapsed: some View {
        HStack(spacing: 2) {
            if store.shown.isEmpty {
                Blob(mood: .idle, color: Color(white: 0.5), seed: 0, size: 30)
            }
            ForEach(store.shown) { a in
                Blob(mood: a.mood, color: a.color, seed: a.seed, size: 30)
                    .onTapGesture { store.pickedAction = nil; store.openId = a.id; store.collapsed = false }
            }
            if store.needsYouCount > 0 {
                Text("\(store.needsYouCount)").font(.system(size: 10, weight: .heavy)).foregroundColor(.black)
                    .frame(width: 16, height: 16).background(Circle().fill(lime))
            }
            IconButton(symbol: "chevron.down") { store.collapsed = false }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
        .background(DragHandle())
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var panel: NSPanel!
    var server: Server!
    var timer: Timer?
    var tailTimer: Timer?
    var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: Root(store: store) { [weak self] size in self?.fit(size) })
        placeAtStart()
        panel.orderFrontRegardless()

        server = Server(store: store)
        do { try server.start() } catch { NSLog("agent-huddle: server failed: \(error)"); NSApp.terminate(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.store.tidy() }
        tailTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.store.pollTranscripts() }

        for sig in [SIGTERM, SIGINT] {  // launchd stops us with SIGTERM: clean up server.json first
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signals.append(s)
        }
        // `kill -USR1 <pid>` saves the panel to ~/.agent-huddle/snapshot.png (for checking the look).
        signal(SIGUSR1, SIG_IGN)
        let snap = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        snap.setEventHandler { [weak self] in self?.snapshot() }
        snap.resume()
        signals.append(snap)
        // `kill -USR2 <pid>` opens the live view of the busiest agent (or closes it), for checking without a click.
        signal(SIGUSR2, SIG_IGN)
        let peek = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        peek.setEventHandler { [weak self] in
            guard let s = self?.store else { return }
            s.collapsed = false
            s.openId = s.openId == nil ? s.agents.max(by: { $0.actions.count < $1.actions.count })?.id : nil
        }
        peek.resume()
        signals.append(peek)
    }

    private func snapshot() {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: stateDir.appendingPathComponent("snapshot.png"))
    }

    func applicationWillTerminate(_ note: Notification) {
        for c in store.held.values { Server.reply(c, "{\"retry\":true}") }  // hook re-asks the next widget (VS Code still shows it)
        try? FileManager.default.removeItem(at: serverFile)
    }

    /// Restore the saved top-right corner, or start in the screen's top-right.
    private func placeAtStart() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var corner = NSPoint(x: screen.maxX - 16, y: screen.maxY - 16)
        if let s = UserDefaults.standard.string(forKey: "corner") {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(p) }) { corner = p }
        }
        var f = panel.frame
        f.origin = NSPoint(x: corner.x - f.width, y: corner.y - f.height)
        panel.setFrame(f, display: false)
    }

    /// Resize to the content, keeping the top edge and (on the right half of the screen) the right edge fixed.
    func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, let panel else { return }
        var f = panel.frame
        let screenMid = (panel.screen ?? NSScreen.main)?.frame.midX ?? 0
        let anchorRight = f.midX > screenMid
        let top = f.maxY, right = f.maxX
        f.size = size
        f.origin.y = top - size.height
        if anchorRight { f.origin.x = right - size.width }
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    func windowDidChangeOcclusionState(_ note: Notification) {
        visibility.on = panel.occlusionState.contains(.visible)
    }

    func windowDidMove(_ note: Notification) {
        if !testMode { UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)), forKey: "corner") }
    }
}

// One widget at a time.
if let data = try? Data(contentsOf: serverFile),
   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let pid = json["pid"] as? Int, pid != Int(getpid()), kill(pid_t(pid), 0) == 0 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
