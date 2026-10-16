import AppKit
import SwiftUI

// MARK: - Claude Code hooks

/// Adds (or removes) Peaky's hooks in ~/.claude/settings.json, so nobody has to paste JSON by hand.
/// Always keeps a backup next to it first, and leaves every other setting and hook alone.
enum ClaudeHooks {
    enum State: Equatable { case notInstalled, partial, installed, unreadable }

    /// Tests point these somewhere harmless.
    static var settingsOverride: URL?
    static var commandOverride: String?

    static var settingsURL: URL {
        settingsOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var command: String {
        commandOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/peaky-cli").path + " claude"
    }
    /// Everything except PermissionRequest is fire-and-forget; that one waits for Allow / Deny.
    static let events = ["Stop", "Notification", "PreToolUse", "PostToolUse", "UserPromptSubmit", "PermissionRequest"]

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let c = hook["command"] as? String else { return false }
        return c.hasSuffix("peaky-cli claude") || c.hasSuffix("/peaky claude") || c == "peaky claude"
    }

    private static func hook(for event: String) -> [String: Any] {
        event == "PermissionRequest"
            ? ["type": "command", "command": command, "timeout": 3600]
            : ["type": "command", "command": command, "timeout": 5, "async": true]
    }

    /// nil = the file exists but isn't JSON we can safely rewrite.
    private static func load() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static var state: State {
        guard let s = load() else { return .unreadable }
        let hooks = s["hooks"] as? [String: Any] ?? [:]
        let have = events.filter { e in
            (hooks[e] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs)
            }
        }
        return have.isEmpty ? .notInstalled : have.count == events.count ? .installed : .partial
    }

    static func install() throws { try edit(adding: true) }
    static func remove() throws { try edit(adding: false) }

    private static func edit(adding: Bool) throws {
        guard var s = load() else {
            throw NSError(domain: "Peaky", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "~/.claude/settings.json isn't plain JSON, so Peaky won't rewrite it. Add the hooks from the README by hand."])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.peaky-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for e in events {
            // Drop our old entries (wherever the app used to live), keep everyone else's.
            var groups: [[String: Any]] = (hooks[e] as? [[String: Any]] ?? []).compactMap { group in
                var g = group
                let rest = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0) }
                if rest.isEmpty { return nil }
                g["hooks"] = rest
                return g
            }
            if adding { groups.append(["hooks": [hook(for: e)]]) }
            hooks[e] = groups.isEmpty ? nil : groups
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

// MARK: - Update check

/// Once a day, asks GitHub for the latest release (no data about you is sent). When it's newer, the menu
/// shows "Update available" and one short alert appears in the notch.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "iamsumanp/Peaky"

    @Published private(set) var latestVersion: String?
    @Published private(set) var latestURL: URL?
    @Published private(set) var status = ""
    private var timer: Timer?

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var updateAvailable: Bool { latestVersion.map { Self.isNewer($0, than: current) } ?? false }

    func start() {
        timer?.invalidate()
        guard Prefs.bool(.checkUpdates) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        if userInitiated { status = "Checking…" }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Peaky/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.handle(data, error, userInitiated: userInitiated) }
        }.resume()
    }

    private func handle(_ data: Data?, _ error: Error?, userInitiated: Bool) {
        guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String else {
            if userInitiated { status = "Couldn't reach GitHub" }
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestVersion = version
        latestURL = (o["html_url"] as? String).flatMap(URL.init(string:))
        guard updateAvailable else {
            status = userInitiated ? "You're up to date" : ""
            return
        }
        status = "Peaky \(version) is available"
        // One alert per new version, never more.
        let seenKey = "updateAnnounced"
        if UserDefaults.standard.string(forKey: seenKey) != version || userInitiated {
            UserDefaults.standard.set(version, forKey: seenKey)
            var n = Notice(key: "update", symbol: "arrow.down.app.fill", tint: Theme.accent, title: "Peaky \(version)",
                           detail: "Update", detailTint: Theme.accent, duration: 8)
            n.openURL = latestURL
            IslandHub.post(.notice(n))
        }
    }

    func openDownload() {
        NSWorkspace.shared.open(latestURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
    }

    /// "1.10" > "1.9"; "1.1" == "1.1.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Settings rows

struct ClaudeHooksRow: View {
    @State private var state = ClaudeHooks.state
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude Code hooks")
                Spacer()
                switch state {
                case .installed:
                    Label("Set up", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Remove") { run(ClaudeHooks.remove) }
                case .partial:
                    Button("Repair") { run(ClaudeHooks.install) }
                case .notInstalled:
                    Button("Set up Claude Code") { run(ClaudeHooks.install) }
                case .unreadable:
                    Text("settings.json isn't plain JSON").foregroundStyle(.secondary)
                }
            }
            Text(error ?? "Adds Peaky's hooks to ~/.claude/settings.json (a backup is kept as settings.json.peaky-backup). New Claude sessions pick them up.")
                .font(.caption)
                .foregroundStyle(error == nil ? Color.secondary : .red)
        }
        .onAppear { state = ClaudeHooks.state }
    }

    private func run(_ f: () throws -> Void) {
        do { try f(); error = nil } catch { self.error = error.localizedDescription }
        state = ClaudeHooks.state
    }
}

struct UpdateRow: View {
    @ObservedObject var updater = Updater.shared
    @AppStorage(Prefs.Key.checkUpdates.rawValue) private var auto = true

    var body: some View {
        Toggle("Check for updates once a day", isOn: $auto)
            .onChange(of: auto) { updater.start() }
        HStack {
            Text("Peaky \(updater.current)")
            if !updater.status.isEmpty {
                Text("· " + updater.status).foregroundStyle(updater.updateAvailable ? Theme.accent : .secondary)
            }
            Spacer()
            if updater.updateAvailable {
                Button("Download") { updater.openDownload() }
            } else {
                Button("Check Now") { updater.check(userInitiated: true) }
            }
        }
    }
}
