import AppKit

/// Claude asking for permission, answerable from the notch. The `peaky claude` hook is waiting for the reply.
struct ClaudeAsk: Equatable {
    let id: String
    /// The session's notice key, cleared once answered.
    let key: String
    let tool: String      // "Bash"
    let summary: String   // "npm run build"

    func reply(_ decision: String) {
        Channel.post(Channel.reply, ["id": id, "decision": decision])
    }

    func answer(allow: Bool) {
        reply(allow ? "allow" : "deny")
        IslandHub.post(.clear(key))
    }
}

/// Where a Claude session lives, so clicking its alert can take you back to it.
struct SessionFocus: Equatable {
    let app: String?   // bundle id of the app Claude runs in
    let tty: String?   // "/dev/ttys003" when it runs in a terminal
    let cwd: String?

    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    func go() {
        let app = app ?? ""
        // Terminals: bring the exact tab forward. The tty goes into AppleScript source, so only ever a plain
        // "/dev/ttys012" — never text that could close the string and add commands.
        if let tty, Self.isSafeTTY(tty) {
            if app == "com.apple.Terminal", Self.run("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                            end if
                        end repeat
                    end repeat
                    activate
                end tell
                """) { return }
            if app == "com.googlecode.iterm2", Self.run("""
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    tell t to select
                                    tell s to select
                                end if
                            end repeat
                        end repeat
                    end repeat
                    activate
                end tell
                """) { return }
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return }
        // Editors: open the project folder, which brings its window forward.
        if let cwd, Self.editors.contains(app) {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // The Claude app (no link to a single session exists) or anything else: just bring it forward.
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    static func isSafeTTY(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys[0-9]{1,4}$"#, options: .regularExpression) != nil
    }

    @discardableResult
    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
