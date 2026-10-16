// peaky — send a one-line alert to the Peaky island from the terminal.
//
//   peaky "Build done"                         title only
//   peaky "Deploy" "staging ✓"                 title + detail (right of the notch)
//   peaky -s hammer.fill -c orange "Building"  SF Symbol + colour (red green blue orange yellow purple pink gray claude #RRGGBB)
//   peaky -t 6 -o https://github.com "PR open" seconds on screen, and what a click opens (URL or bundle id)
//   peaky run npm test                         run a command, then report ✓/✗ with how long it took
//   peaky claude                               Claude Code hook (reads the hook JSON from stdin)
import AppKit
import CryptoKit

// MARK: Signed channel (same as Sources/Peaky/Channel.swift — keep in sync)
//
// Distributed notifications can be posted and observed by any app, so every message is signed with a key in
// ~/Library/Application Support/Peaky/channel.key (mode 600). Peaky ignores unsigned alerts, and this tool
// ignores unsigned answers — another app can't approve Claude's permission requests.

let channelKey: SymmetricKey = {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Peaky")
    let url = dir.appendingPathComponent("channel.key")
    if let d = try? Data(contentsOf: url), d.count == 32 { return SymmetricKey(data: d) }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    if !fm.createFile(atPath: url.path, contents: fresh, attributes: [.posixPermissions: 0o600]),
       let d = try? Data(contentsOf: url), d.count == 32 {
        return SymmetricKey(data: d)
    }
    return SymmetricKey(data: (try? Data(contentsOf: url)) ?? fresh)
}()

func mac(_ s: String) -> String {
    HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: channelKey).map { String(format: "%02x", $0) }.joined()
}

func seal(_ json: String) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: ["p": json, "m": mac(json)]) else { return "" }
    return String(decoding: d, as: UTF8.self)
}

/// The inner object if the message is signed with our key.
func openSealed(_ sealed: Any?) -> [String: Any]? {
    guard let sealed = sealed as? String, let d = sealed.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
          let p = o["p"], let m = o["m"], m.count == 64 else { return nil }
    let expected = Array(mac(p).utf8), given = Array(m.utf8)
    var diff: UInt8 = 0
    for i in 0..<64 { diff |= expected[i] ^ given[i] }
    guard diff == 0, let pd = p.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: pd) as? [String: Any]
}

func send(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8) else { return }
    DistributedNotificationCenter.default().postNotificationName(
        .init("io.github.iamsumanp.peaky.notify"), object: seal(json), userInfo: nil, deliverImmediately: true)
}

func usage() -> Never {
    print("""
    usage: peaky [-s symbol] [-c color] [-t seconds] [-o url|bundle-id] <title> [detail]
           peaky run <command> [args…]
           peaky claude            (Claude Code hook; reads JSON on stdin)
    """)
    exit(2)
}

/// The GUI app this shell (or Claude Code) is running inside, e.g. Terminal, iTerm, VS Code, Claude.
let hostApp = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]

/// Last ~300 Claude hook events, to check the hooks really fire: ~/Library/Logs/Peaky/claude-hooks.log
func claudeLog(_ line: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peaky")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("claude-hooks.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    lines.append("\(stamp) \(line)")
    try? (lines.suffix(300).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// The terminal the Claude session runs in ("/dev/ttys003"), from the nearest ancestor that has one.
/// Hook processes themselves have no controlling terminal.
func sessionTTY() -> String? {
    var pid = getppid()
    for _ in 0..<6 where pid > 1 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, S_IFCHR) { return "/dev/" + String(cString: name) }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

/// "cubone" for ~/Desktop/cubone, and also for a worktree inside it (…/cubone/.claude/worktrees/fix-x).
func projectName(_ cwd: String) -> String {
    let parts = URL(fileURLWithPath: cwd).pathComponents
    if let i = parts.firstIndex(of: ".claude"), i > 0 { return parts[i - 1] }
    return parts.last ?? cwd
}

/// One line saying what Claude wants to do: the command, the file, the site…
func askSummary(tool: String, input: [String: Any]) -> String {
    func short(_ path: String) -> String { URL(fileURLWithPath: path).pathComponents.suffix(2).joined(separator: "/") }
    if let c = input["command"] as? String { return c.replacingOccurrences(of: "\n", with: " ") }
    if let f = input["file_path"] as? String ?? input["notebook_path"] as? String { return short(f) }
    if let u = input["url"] as? String { return URL(string: u)?.host ?? u }
    if let q = input["pattern"] as? String ?? input["query"] as? String ?? input["prompt"] as? String ?? input["description"] as? String {
        return q.replacingOccurrences(of: "\n", with: " ")
    }
    return ""
}

/// Is "Allow / Deny in the notch" on in Peaky's settings (default on)?
var notchApproveEnabled: Bool {
    UserDefaults(suiteName: "io.github.iamsumanp.peaky")?.object(forKey: "claudeNotchApprove") as? Bool ?? true
}

/// Show the request in the notch and wait for Allow / Deny. Returns nil when there is no answer from the notch:
/// Peaky isn't running, the request was handled in Claude itself, or it timed out — Claude's own prompt decides then.
func waitForNotchDecision(id: String, key: String, timeout: TimeInterval) -> String? {
    let center = DistributedNotificationCenter.default()
    var decision: String?
    var acked = false
    var done = false
    let reply = center.addObserver(forName: .init("io.github.iamsumanp.peaky.reply"), object: nil, queue: nil) { n in
        guard let o = openSealed(n.object), o["id"] as? String == id else { return }
        switch o["decision"] as? String {
        case "shown": acked = true
        case let d?: decision = d; done = true
        default: break
        }
    }
    // Anything else about this session (it carried on, finished, a new prompt) means it was answered in Claude.
    let other = center.addObserver(forName: .init("io.github.iamsumanp.peaky.notify"), object: nil, queue: nil) { n in
        guard let o = openSealed(n.object) else { return }
        let k = o["clear"] as? String ?? o["key"] as? String
        // (Claude Code's own "needs permission" Notification ~6 s later is the same wait, not an answer.)
        if k == key, o["kind"] as? String != "wait" { done = true }
    }
    defer { center.removeObserver(reply); center.removeObserver(other) }
    let start = Date()
    while !done {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let t = Date().timeIntervalSince(start)
        if !acked && t > 2 { return nil }   // Peaky didn't pick it up
        if t > timeout { return nil }
    }
    return decision
}

func formatDuration(_ s: Double) -> String {
    if s < 60 { return String(format: "%.1fs", s) }
    let m = Int(s) / 60, r = Int(s) % 60
    return m < 60 ? "\(m)m \(r)s" : "\(m / 60)h \(m % 60)m"
}

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { usage() }

switch first {
case "watch":
    // Started by Peaky at launch: `peaky-cli watch <pid> <app path>`. If Peaky crashes, open it again.
    // "Crashed" = macOS wrote a crash report for it right then; Quit, pkill and Force Quit don't, so those
    // stay closed. At most 3 restarts in 10 minutes, so a crash loop can't spin forever.
    guard args.count >= 3, let pid = pid_t(args[1]) else { usage() }
    let appPath = args[2]
    let kq = kqueue()
    var ev = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                    fflags: NOTE_EXIT, data: 0, udata: nil)
    guard kevent(kq, &ev, 1, nil, 0, nil) == 0 else { exit(0) }   // already gone
    var out = kevent()
    _ = kevent(kq, nil, 0, &out, 1, nil)
    let exited = Date()

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports")
    var crashed = false
    for _ in 0..<20 where !crashed {   // reports appear within a second or two
        Thread.sleep(forTimeInterval: 0.5)
        let files = (try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.creationDateKey])) ?? []
        crashed = files.contains { f in
            f.lastPathComponent.hasPrefix("Peaky") && f.pathExtension == "ips" &&
            ((try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > exited.addingTimeInterval(-3)
        }
    }
    let logDir = home.appendingPathComponent("Library/Logs/Peaky")
    try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
    let log = logDir.appendingPathComponent("restarts.log")
    guard crashed else { exit(0) }
    let recent = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        .compactMap { Double($0.split(separator: " ").first ?? "") }
        .filter { Date().timeIntervalSince1970 - $0 < 600 }
    guard recent.count < 3 else { exit(0) }
    let line = "\(Date().timeIntervalSince1970) crashed (pid \(pid)), reopening\n"
    if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: log, atomically: true, encoding: .utf8) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [appPath]
    try? p.run()
    p.waitUntilExit()

case "run":
    let cmd = Array(args.dropFirst())
    guard !cmd.isEmpty else { usage() }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = cmd
    let started = Date()
    do { try p.run() } catch { fputs("peaky: \(error.localizedDescription)\n", stderr); exit(127) }
    // Let Ctrl-C reach the child, not just us.
    signal(SIGINT, SIG_IGN)
    p.waitUntilExit()
    let ok = p.terminationStatus == 0
    let took = formatDuration(Date().timeIntervalSince(started))
    var payload: [String: Any] = [
        "title": cmd.prefix(3).joined(separator: " "),
        "detail": ok ? "✓ \(took)" : "✗ exit \(p.terminationStatus)",
        "symbol": ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
        "tint": ok ? "green" : "red",
        "duration": ok ? 4 : 6,
    ]
    if let hostApp { payload["open"] = hostApp }
    send(payload)
    exit(p.terminationStatus)

case "claude":
    // Claude Code passes the hook event as JSON on stdin.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let hook = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
    let event = hook["hook_event_name"] as? String ?? "Stop"
    let cwd = hook["cwd"] as? String ?? FileManager.default.currentDirectoryPath
    let project = projectName(cwd)
    let key = "claude-" + cwd
    let message = hook["message"] as? String ?? ""
    let kind = (hook["notification_type"] as? String ?? "").lowercased()
    claudeLog("\(event) type=\(kind) project=\(project) message=\(message)")

    var payload: [String: Any] = ["title": "Claude · \(project)", "symbol": "claude", "tint": "claude", "key": key,
                                  "priority": 1]
    if let hostApp { payload["open"] = hostApp }
    // Clicking the alert brings back this session: its terminal tab, editor window, or the Claude app.
    var focus: [String: Any] = ["cwd": cwd]
    if let hostApp { focus["app"] = hostApp }
    if let tty = sessionTTY() { focus["tty"] = tty }
    payload["focus"] = focus
    // "Claude is working": a start (you sent a prompt) or a heartbeat (it's using tools). Nested, so the
    // Allow / Deny wait loop doesn't mistake it for the session moving on.
    let working: [String: Any] = ["key": key, "title": "Claude · \(project)", "focus": focus]
    switch event {
    case "Stop":
        payload["detail"] = "Finished"
        payload["duration"] = 4
    case "PermissionRequest":
        // Fires the moment Claude shows a permission prompt or a question (the Notification event below
        // only comes ~6 s later). Print nothing: output here could be read as an allow/deny decision.
        let tool = hook["tool_name"] as? String ?? ""
        let question = tool == "AskUserQuestion" || tool == "ExitPlanMode"
        payload["detail"] = tool == "AskUserQuestion" ? "Has a question" : tool == "ExitPlanMode" ? "Plan ready" : "Needs permission"
        payload["kind"] = "wait"
        // Allow / Deny from the notch — only in the Claude app, where its own prompt stays up alongside this
        // hook and whichever answers first wins. (In a terminal it isn't documented that the prompt shows
        // while a hook runs, so there the hook stays out of the way.)
        guard !question, notchApproveEnabled, hostApp == "com.anthropic.claudefordesktop",
              !NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.iamsumanp.peaky").isEmpty else { break }
        let id = UUID().uuidString
        let input = hook["tool_input"] as? [String: Any] ?? [:]
        let shortTool = tool.hasPrefix("mcp__") ? String(tool.split(separator: "__").last ?? "") : tool
        payload["ask"] = ["id": id, "tool": shortTool, "summary": askSummary(tool: tool, input: input)]
        send(payload)
        let wait = UserDefaults(suiteName: "io.github.iamsumanp.peaky")?.double(forKey: "claudeWaitSeconds") ?? 0
        guard let d = waitForNotchDecision(id: id, key: key, timeout: min(max(wait, 30), 3500)) else { exit(0) }
        claudeLog("PermissionRequest decided in notch: \(d) project=\(project) tool=\(tool)")
        var decision: [String: Any] = ["behavior": d == "allow" ? "allow" : "deny"]
        if d != "allow" { decision["message"] = "Denied from the Peaky notch." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data) }
        exit(0)
    case "Notification":
        let m = message.lowercased()
        if kind == "idle_prompt" || m.contains("waiting for your input") {
            // The 60-second idle reminder: "Finished" already said it. But it also means Claude isn't working
            // any more — the only sign we get after you interrupt it (Stop doesn't fire then).
            send(["done": key])
            exit(0)
        }
        payload["detail"] = kind == "permission_prompt" || m.contains("permission") ? "Needs permission" : "Needs you"
        payload["kind"] = "wait" // stays for the time chosen in Peaky's settings
    case "UserPromptSubmit", "PostToolUse":
        // Claude carried on (permission granted / you replied): drop any waiting alert; it's working.
        send(["clear": key, "working": working.merging(["start": event == "UserPromptSubmit"]) { $1 }])
        exit(0)
    case "PreToolUse":
        // About to run a tool (maybe a long build): still working.
        send(["working": working])
        exit(0)
    case "SessionEnd", "StopFailure":
        send(["clear": key, "done": key])
        exit(0)
    default:
        exit(0)
    }
    send(payload)

default:
    var payload: [String: Any] = [:]
    var rest: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-s", "--symbol": payload["symbol"] = args.isEmpty ? nil : args.removeFirst()
        case "-c", "--color": payload["tint"] = args.isEmpty ? nil : args.removeFirst()
        case "-t", "--time": payload["duration"] = args.isEmpty ? nil : Double(args.removeFirst())
        case "-o", "--open": payload["open"] = args.isEmpty ? nil : args.removeFirst()
        case "-h", "--help": usage()
        default: rest.append(a)
        }
    }
    guard let title = rest.first else { usage() }
    payload["title"] = title
    if rest.count > 1 { payload["detail"] = rest[1...].joined(separator: " ") }
    if payload["open"] == nil, let hostApp { payload["open"] = hostApp }
    send(payload)
}
