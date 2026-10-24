import Foundation
import SwiftUI
import Testing
@testable import Peaky

// The logic that's easy to break without noticing: version compare, the Claude hooks editor, meeting timing,
// the signed channel, and a few formatters. Run with `swift test`.

@Suite struct VersionCompare {
    @Test func newer() {
        #expect(Updater.isNewer("1.2", than: "1.1"))
        #expect(Updater.isNewer("1.10", than: "1.9"))
        #expect(Updater.isNewer("2.0", than: "1.99.9"))
        #expect(Updater.isNewer("1.1.1", than: "1.1"))
    }

    @Test func notNewer() {
        #expect(!Updater.isNewer("1.1", than: "1.1"))
        #expect(!Updater.isNewer("1.1.0", than: "1.1"))
        #expect(!Updater.isNewer("1.0", than: "1.1"))
        #expect(!Updater.isNewer("1.9", than: "1.10"))
    }
}

@Suite(.serialized) struct ClaudeHooksEditor {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peaky-tests-\(UUID().uuidString)")
    var file: URL { dir.appendingPathComponent("settings.json") }

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ClaudeHooks.settingsOverride = file
        ClaudeHooks.commandOverride = "/Applications/Peaky.app/Contents/MacOS/peaky-cli claude"
    }

    private func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    private func commands(_ event: String) throws -> [String] {
        let hooks = try json()["hooks"] as? [String: Any] ?? [:]
        return (hooks[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func installKeepsOtherSettingsAndIsIdempotent() throws {
        try #"{"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeHooks.state == .notInstalled)
        try ClaudeHooks.install()
        try ClaudeHooks.install()
        #expect(ClaudeHooks.state == .installed)
        #expect(try json()["model"] as? String == "opus")
        #expect(try commands("Stop") == ["say done", ClaudeHooks.command])
        #expect(try commands("PermissionRequest") == [ClaudeHooks.command])
        // PermissionRequest waits for Allow / Deny; everything else is async.
        let perm = ((try json()["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]]
        #expect(perm[0]["async"] == nil)
        #expect(perm[0]["timeout"] as? Int == 3600)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json.peaky-backup").path))
    }

    @Test func removeLeavesOnlyOtherHooks() throws {
        try #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        try ClaudeHooks.install()
        try ClaudeHooks.remove()
        #expect(ClaudeHooks.state == .notInstalled)
        #expect(try commands("Stop") == ["say done"])
        #expect((try json()["hooks"] as? [String: Any])?["PermissionRequest"] == nil)
    }

    @Test func movedAppIsReplacedNotDuplicated() throws {
        try #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/old/place/peaky-cli claude"}]}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeHooks.state == .partial)
        try ClaudeHooks.install()
        #expect(try commands("Stop") == [ClaudeHooks.command])
    }

    @Test func missingFileIsCreated() throws {
        #expect(ClaudeHooks.state == .notInstalled)
        try ClaudeHooks.install()
        #expect(ClaudeHooks.state == .installed)
    }

    @Test func refusesFilesThatAreNotPlainJSON() throws {
        try "// a comment\n{}".write(to: file, atomically: true, encoding: .utf8)
        #expect(ClaudeHooks.state == .unreadable)
        #expect(throws: Error.self) { try ClaudeHooks.install() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "// a comment\n{}")
    }
}

@Suite struct NextMeeting {
    let day = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!

    func event(_ title: String, from: Double, to: Double) -> CalEvent {
        CalEvent(id: title, title: title, start: day.addingTimeInterval(from * 60), end: day.addingTimeInterval(to * 60),
                 allDay: false, color: .blue, joinURL: nil)
    }

    @Test func showsTheNextOneRightAfterAMeetingEnds() {
        let done = event("Sync", from: -60, to: -2), next = event("Standup", from: 25, to: 40)
        #expect(CalendarService.upNext(today: [done, next], upcoming: [next], now: day)?.title == "Standup")
    }

    @Test func farAwayMeetingOnlyForFiveMinutes() {
        let next = event("Review", from: 120, to: 150)
        let justEnded = event("Sync", from: -60, to: -2), endedLongAgo = event("Sync", from: -60, to: -10)
        #expect(CalendarService.upNext(today: [justEnded, next], upcoming: [next], now: day)?.title == "Review")
        #expect(CalendarService.upNext(today: [endedLongAgo, next], upcoming: [next], now: day) == nil)
    }

    @Test func withinTheHourStaysTheWholeGap() {
        let ended = event("Sync", from: -60, to: -20), next = event("Standup", from: 30, to: 45)
        #expect(CalendarService.upNext(today: [ended, next], upcoming: [next], now: day)?.title == "Standup")
    }

    @Test func hiddenMeetingCountsAsOverFromWhenItWasHidden() {
        // Left a 2-hour call 5 minutes in; the next meeting is in 40 minutes → show it now.
        let call = event("Long call", from: -5, to: 115), next = event("Standup", from: 40, to: 55)
        #expect(CalendarService.upNext(today: [call, next], upcoming: [call, next], now: day) == nil)
        #expect(CalendarService.upNext(today: [call, next], upcoming: [call, next], now: day,
                                       hidden: ["Long call": day])?.title == "Standup")
    }

    @Test func nothingBeforeTheFirstMeetingOfTheDay() {
        let next = event("Standup", from: 25, to: 40)
        #expect(CalendarService.upNext(today: [next], upcoming: [next], now: day) == nil)
    }
}

@Suite struct SignedChannel {
    @Test func roundTrip() {
        let json = #"{"title":"Claude","detail":"Finished"}"#
        #expect(Channel.open(Channel.seal(json)) == json)
    }

    @Test func rejectsUnsignedAndTampered() {
        #expect(Channel.open(#"{"title":"FORGED"}"#) == nil)
        #expect(Channel.open(#"{"p":"{\"id\":\"x\",\"decision\":\"allow\"}","m":"\#(String(repeating: "0", count: 64))"}"#) == nil)
        let sealed = Channel.seal(#"{"decision":"deny"}"#)
        #expect(Channel.open(sealed.replacingOccurrences(of: "deny", with: "allow")) == nil)
        #expect(Channel.open(nil) == nil)
    }
}

@Suite struct Parsing {
    @Test func claudeAskAndFocus() throws {
        let json = #"""
        {"title":"Claude · my-app","detail":"Needs permission","key":"claude-/tmp/my-app","kind":"wait",
         "focus":{"app":"com.apple.Terminal","tty":"/dev/ttys004","cwd":"/tmp/my-app"},
         "ask":{"id":"abc","tool":"Bash","summary":"npm test"}}
        """#
        let n = try #require(Notice(cliJSON: json))
        #expect(n.sticky)
        #expect(n.ask?.summary == "npm test")
        #expect(n.ask?.key == "claude-/tmp/my-app")
        #expect(n.focus?.tty == "/dev/ttys004")
    }

    @Test func ttyThatCouldInjectAppleScriptIsRejected() {
        #expect(SessionFocus.isSafeTTY("/dev/ttys004"))
        #expect(!SessionFocus.isSafeTTY(#"/dev/ttys004" then do shell script "id"#))
        #expect(!SessionFocus.isSafeTTY("/dev/ttys004\n"))
        #expect(!SessionFocus.isSafeTTY("/etc/passwd"))
    }
}

@Suite struct Formatting {
    @Test func meetingSpans() {
        #expect(CalEvent.span(62 * 60) == "1 hr 2 mins")
        #expect(CalEvent.span(10 * 60) == "10 mins")
        #expect(CalEvent.span(60) == "1 min")
        #expect(CalEvent.span(120 * 60) == "2 hrs")
        #expect(CalEvent.span(1) == "1 min")
    }

    @Test func shortSpansForTheCollapsedNotch() {
        #expect(CalEvent.spanShort(62 * 60) == "1h 2m")
        #expect(CalEvent.spanShort(10 * 60) == "10m")
        #expect(CalEvent.spanShort(120 * 60) == "2h")
        #expect(CalEvent.spanShort(1) == "1m")
    }

    @Test func trackTimes() {
        #expect(Scrubber.time(0) == "0:00")
        #expect(Scrubber.time(75.9) == "1:15")
        #expect(Scrubber.time(3725) == "1:02:05")
    }

    @Test func downloadNames() {
        #expect(DownloadsMonitor.cleanName(URL(fileURLWithPath: "/x/report.pdf.crdownload")) == "report.pdf")
        #expect(DownloadsMonitor.cleanName(URL(fileURLWithPath: "/x/movie.mp4.download")) == "movie.mp4")
        #expect(DownloadsMonitor.cleanName(URL(fileURLWithPath: "/x/a.zip.part")) == "a.zip")
        #expect(DownloadsMonitor.cleanName(nil) == "Download")
    }
}

@Suite struct ShelfOrder {
    @Test func droppedFilesGoOnTopAndAreMarkedNew() {
        let shelf = ShelfStore()
        let saved = shelf.items
        defer { shelf.clear(); shelf.add(saved.reversed().reversed()) }
        shelf.clear()
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b"), c = URL(fileURLWithPath: "/tmp/c")
        shelf.add([a, b])
        shelf.add([c, a])          // a again: moves up with c, no duplicate
        #expect(shelf.items == [c, a, b])
        #expect(shelf.justAdded == [c, a])
    }
}

@Suite(.serialized) struct ShelfExpiry {
    @Test func eachFileExpiresOnItsOwnClock() {
        let key = Prefs.Key.shelfExpireHours.rawValue
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        let shelf = ShelfStore()
        shelf.clear()
        let old = URL(fileURLWithPath: "/tmp/old"), fresh = URL(fileURLWithPath: "/tmp/fresh")
        shelf.add([old, fresh])
        let now = Date()
        shelf.setAdded(old, at: now.addingTimeInterval(-5 * 3600))
        shelf.setAdded(fresh, at: now.addingTimeInterval(-10 * 60))

        UserDefaults.standard.set(0.0, forKey: key)        // Never
        shelf.prune(now: now)
        #expect(shelf.items.count == 2)

        UserDefaults.standard.set(4.0, forKey: key)        // After 4 hours: only the 5-hour-old one goes
        shelf.prune(now: now)
        #expect(shelf.items == [fresh])
        shelf.clear()
    }
}
