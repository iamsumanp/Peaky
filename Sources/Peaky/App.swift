import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Preferences

enum Prefs {
    enum Key: String {
        case display, openOnHover, showMusicActivity, showHUD, hudReplace, pet
        case awakeDisplay, awakeDefault, awakeAtLaunch
        case notifyCharging, notifyBluetooth, notifyCalendar, claudeWaitSeconds, claudeNotchApprove, claudeQuietWhenFront, checkUpdates, hideFromCapture, claudeShowWorking, shelfExpireHours
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            Key.display.rawValue: "notch",
            Key.openOnHover.rawValue: true,
            Key.pet.rawValue: "none",
            Key.awakeDisplay.rawValue: true,
            Key.awakeDefault.rawValue: 0.0,
            Key.awakeAtLaunch.rawValue: false,
            Key.claudeWaitSeconds.rawValue: 120,
            Key.claudeNotchApprove.rawValue: true,
            Key.claudeQuietWhenFront.rawValue: true,
            Key.checkUpdates.rawValue: true,
            Key.hideFromCapture.rawValue: true,
            Key.claudeShowWorking.rawValue: true,
            Key.shelfExpireHours.rawValue: 0.0,
            Key.showMusicActivity.rawValue: true,
            Key.showHUD.rawValue: true,
            Key.hudReplace.rawValue: false,
            Key.notifyCharging.rawValue: true,
            Key.notifyBluetooth.rawValue: true,
            Key.notifyCalendar.rawValue: true,
        ])
    }

    static func bool(_ k: Key) -> Bool { UserDefaults.standard.bool(forKey: k.rawValue) }
    static func string(_ k: Key) -> String { UserDefaults.standard.string(forKey: k.rawValue) ?? "" }
    static var pet: PetKind { PetKind(rawValue: string(.pet)) ?? .none }
}

// MARK: - Services

final class Services {
    static let shared = Services()

    let nowPlaying = NowPlaying()
    let volume = VolumeService()
    let brightness = BrightnessService()
    let keyTap = MediaKeyTap()
    let battery = BatteryService()
    let bluetooth = BluetoothService()
    let calendar = CalendarService()
    let shelf = ShelfStore()
    let awake = KeepAwake()
    let downloads = DownloadsMonitor()

    func start() {
        nowPlaying.start()
        keyTap.volume = volume
        keyTap.brightness = brightness
        volume.onChange = { [weak self] v, muted in
            guard let self else { return }
            // With the key tap on, the tap already posted this HUD; this catches changes from elsewhere too.
            guard Prefs.bool(.showHUD) || self.keyTap.running else { return }
            IslandHub.post(.hud(HUDState(kind: .volume, value: v, muted: muted)))
        }
        volume.start()
        battery.start()
        bluetooth.start()
        calendar.start()
        downloads.start()
        awake.restore()
        if !awake.active, Prefs.bool(.awakeAtLaunch) { awake.start(for: KeepAwake.defaultDuration, announce: false) }
        applyPrefs()
    }

    func applyPrefs() {
        if Prefs.bool(.hudReplace) { keyTap.start() } else { keyTap.stop() }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private(set) var controllers: [NotchController] = []
    private var screenSignature = ""
    var pendingDebug: (() -> Void)?
    private var locked = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.register()
        Theme.registerBundledFonts()
        Services.shared.start()
        Updater.shared.start()
        startCrashWatcher()
        IslandMenu.start()
        buildStatusItem()
        rebuildIslands()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Screens settle in a couple of steps when docking; wait for the last one.
            NSObject.cancelPreviousPerformRequests(withTarget: self as Any)
            self?.perform(#selector(AppDelegate.rebuildIslandsIfNeeded), with: nil, afterDelay: 0.5)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.controllers.forEach { $0.setLocked(true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.controllers.forEach { $0.setLocked(false) }
        }
        #if PEAKY_DEBUG
        // Debug hook so states can be previewed from a terminal (debug builds only — `PEAKY_DEBUG=1 ./build.sh`):
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("io.github.iamsumanp.peaky.debug"), object: "expand", deliverImmediately: true)'
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.controllers.first?.model.expand() }
        }, "io.github.iamsumanp.peaky.darwintest" as CFString, nil, .deliverImmediately)
        #endif
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { WakePort.shared.fire() }
        }, "io.github.iamsumanp.peaky.wake" as CFString, nil, .deliverImmediately)
        NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] e in
            if let f = self?.pendingDebug { self?.pendingDebug = nil; f() }
            return e
        }
        #if PEAKY_DEBUG
        DistributedNotificationCenter.default().addObserver(forName: .init("io.github.iamsumanp.peaky.debug"), object: nil, queue: .main) { [weak self] n in
            self?.debug(n.object as? String ?? "")
        }
        #endif
        // Alerts from the `peaky` command line tool (terminal jobs, Claude Code hooks) — signed, see Channel.
        Channel.prepare()
        DistributedNotificationCenter.default().addObserver(forName: Channel.notify, object: nil, queue: .main) { n in
            guard let json = Channel.open(n.object as? String) else { return }
            if let data = json.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               o["clear"] != nil || o["working"] != nil || o["done"] != nil {
                if let key = o["clear"] as? String { IslandHub.post(.clear(key)) }
                if let w = o["working"] as? [String: Any], let key = w["key"] as? String {
                    let f = w["focus"] as? [String: Any]
                    IslandHub.post(.working(ClaudeWork(
                        key: key, title: w["title"] as? String ?? "Claude",
                        focus: f.map { SessionFocus(app: $0["app"] as? String, tty: $0["tty"] as? String, cwd: $0["cwd"] as? String) },
                        restart: w["start"] as? Bool ?? false)))
                }
                if let key = o["done"] as? String { IslandHub.post(.workDone(key)) }
                return
            }
            guard let notice = Notice(cliJSON: json) else { return }
            // Tell the waiting hook its question is on screen (otherwise it gives up and leaves it to Claude).
            notice.ask?.reply("shown")
            IslandHub.post(.notice(notice))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Services.shared.nowPlaying.stop()
    }

    /// Only rebuild when the displays really changed. macOS also posts "screen parameters changed" for
    /// things like the menu bar hiding in a full-screen app, and tearing the island down for those made
    /// it blink.
    @objc func rebuildIslandsIfNeeded() {
        let sig = Displays.selectionSignature + "|" + NSScreen.screens.map {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
            return "\(id):\(NSStringFromRect($0.frame)):\($0.safeAreaInsets.top)"
        }.joined(separator: ",")
        guard sig != screenSignature else { return }
        rebuildIslands()
    }

    @objc func rebuildIslands() {
        screenSignature = Displays.selectionSignature + "|" + NSScreen.screens.map {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
            return "\(id):\(NSStringFromRect($0.frame)):\($0.safeAreaInsets.top)"
        }.joined(separator: ",")
        controllers.forEach { $0.tearDown() }
        controllers = Displays.selectedScreens.map { NotchController(screen: $0) }
        if locked { controllers.forEach { $0.setLocked(true) } }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Peaky")
            ?? NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Peaky")
        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, so the meeting list is current
        item.menu = menu
        statusItem = item
    }

    // MARK: Menu bar dropdown (today's meetings, like MeetingBar)

    @objc private func openUpdate() { Updater.shared.openDownload() }
    @objc private func unhideMeetings() { Services.shared.calendar.unhideAll() }

    /// A tiny `peaky-cli watch` process that reopens Peaky if it crashes (see tools/peaky-cli.swift).
    private func startCrashWatcher() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/peaky-cli")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["watch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let up = Updater.shared
        if up.updateAvailable, let v = up.latestVersion {
            let item = NSMenuItem(title: "Update available: Peaky \(v)…", action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.app.fill", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let cal = Services.shared.calendar
        let now = Date()
        if let h = cal.hiddenCurrent {
            let item = NSMenuItem(title: "Show “\(h.title)” in the Notch Again", action: #selector(unhideMeetings), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if cal.authorized {
            if let next = cal.events.first(where: { !$0.allDay && $0.joinURL != nil && $0.end > now
                                                    && $0.start.timeIntervalSinceNow < 60 * 60 }) {
                let title = next.isNow ? "Join \(next.title) · now" : "Join \(next.title) · \(next.relative)"
                let join = NSMenuItem(title: title, action: #selector(joinMeeting(_:)), keyEquivalent: "")
                join.target = self
                join.representedObject = next.joinURL
                join.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
                menu.addItem(join)
                menu.addItem(.separator())
            }

            let header = NSMenuItem(title: "Today · " + now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                                    action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(string: header.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
            header.isEnabled = false
            menu.addItem(header)

            if cal.today.isEmpty {
                let none = NSMenuItem(title: "No meetings today", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for e in cal.today { menu.addItem(meetingItem(e, now: now)) }
        } else {
            let connect = NSMenuItem(title: "Connect Calendar…", action: #selector(connectCalendar), keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
        }

        menu.addItem(.separator())
        let awake = Services.shared.awake
        let awakeHeader = NSMenuItem(title: awake.active ? "Keep Awake · " + (awake.until == nil ? "on" : awake.remainingShort + " left")
                                                         : "Keep Awake", action: nil, keyEquivalent: "")
        awakeHeader.attributedTitle = NSAttributedString(string: awakeHeader.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        awakeHeader.isEnabled = false
        menu.addItem(awakeHeader)
        let off = NSMenuItem(title: "Off", action: #selector(awakeOff), keyEquivalent: "")
        off.target = self
        off.state = awake.active ? .off : .on
        menu.addItem(off)
        for (i, c) in KeepAwake.choices.enumerated() {
            let it = NSMenuItem(title: c.label, action: #selector(awakeChoice(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.state = awake.active && awake.chosenSeconds == c.seconds ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Island", action: #selector(openIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Peaky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// "10:00 – 10:30   Standup" with the calendar's colour; finished = grey, running = bold, link = clickable.
    private func meetingItem(_ e: CalEvent, now: Date) -> NSMenuItem {
        let time = e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened) + " – "
            + e.end.formatted(date: .omitted, time: .shortened)
        let done = e.end <= now
        let running = e.isNow
        let text = NSMutableAttributedString(string: time + "   ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: done ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: e.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: running ? .semibold : .regular),
            .foregroundColor: done ? NSColor.tertiaryLabelColor : NSColor.labelColor]))
        if running { text.append(NSAttributedString(string: "  · now", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.systemOrange])) }

        let item = NSMenuItem(title: e.title, action: e.joinURL == nil || done ? nil : #selector(joinMeeting(_:)), keyEquivalent: "")
        item.attributedTitle = text
        item.target = self
        item.representedObject = e.joinURL
        item.image = Self.dot(NSColor(e.color), faded: done)
        if e.joinURL != nil, !done { item.toolTip = "Join" }
        return item
    }

    private static func dot(_ color: NSColor, faded: Bool) -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            color.withAlphaComponent(faded ? 0.35 : 1).setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }

    @objc private func joinMeeting(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func connectCalendar() { Services.shared.calendar.requestAccess() }

    @objc private func awakeChoice(_ sender: NSMenuItem) {
        Services.shared.awake.start(for: KeepAwake.choices[sender.tag].seconds)
    }
    @objc private func awakeOff() { Services.shared.awake.stop() }

    private func debug(_ cmd: String) {
        let m = controllers.first?.model
        switch cmd {
        case "expand": m?.expand(tab: .home)
        case "shelfdrop":
            // As if two files were just dropped (they go on top, highlighted).
            let a = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), b = URL(fileURLWithPath: "/Applications/Safari.app")
            Services.shared.shelf.add([a, b]); m?.expand(tab: .shelf)
        case "shelfundrop":
            [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), URL(fileURLWithPath: "/Applications/Safari.app")]
                .forEach(Services.shared.shelf.remove)
        case "dragon", "dragoff": m?.fileDragging = cmd == "dragon"
        case "hidemeeting":
            let cal = Services.shared.calendar
            if let e = cal.agenda { cal.hide(e) }
        case "captureon", "captureoff":
            // Debug screenshots: let the island be captured (or hide it again) without touching the setting.
            NSApp.windows.compactMap { $0 as? NotchPanel }.forEach { $0.sharingType = cmd == "captureon" ? .readOnly : .none }
        case "menutest":
            // A menu opens over the island, the mouse "leaves", the island must stay; then the menu closes.
            let menu = NSMenu()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            m?.collapse()
            let during = m?.expanded ?? false
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                try? "during=\(during) after=\(m?.expanded ?? false)".write(toFile: "/tmp/peaky-menu.txt", atomically: true, encoding: .utf8)
            }
        case "shelfall", "shelfwheel", "shelfgive", "shelfkey", "shelfhit":
            // Debug the shelf grid without touching the mouse; result in /tmp/peaky-shelf.txt.
            guard let panel = controllers.first?.panel, let root = panel.contentView else { return }
            func find(_ v: NSView) -> ShelfCollectionView? {
                if let c = v as? ShelfCollectionView { return c }
                for s in v.subviews { if let c = find(s) { return c } }
                return nil
            }
            guard let cv = find(root), let scroll = cv.enclosingScrollView else {
                try? "no grid".write(toFile: "/tmp/peaky-shelf.txt", atomically: true, encoding: .utf8); return
            }
            if cmd == "shelfall" { cv.selectAll(nil); cv.takeKeyboard() }
            if cmd == "shelfgive" { NotchPanel.giveBackAll() }
            if cmd == "shelfhit" {
                let pt = cv.convert(NSPoint(x: cv.visibleRect.midX, y: cv.visibleRect.midY), to: nil)
                var chain: [String] = []
                var v = root.hitTest(root.convert(pt, from: nil))
                while let view = v { chain.append(String(describing: type(of: view)).prefix(40).description); v = view.superview }
                try? chain.joined(separator: " < ").write(toFile: "/tmp/peaky-hit.txt", atomically: true, encoding: .utf8)
            }
            if cmd == "shelfwheel" {
                let r = cv.window!.convertToScreen(cv.convert(cv.visibleRect, to: nil))
                let primary = NSScreen.screens[0].frame.height
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0)!
                e.location = CGPoint(x: r.midX, y: primary - r.midY)
                if let ns = NSEvent(cgEvent: e) { cv.scrollWheel(with: ns) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let txt = "selected=\(cv.selectionIndexPaths.count) key=\(panel.isKeyWindow) scrollY=\(scroll.contentView.bounds.origin.y) docH=\(cv.frame.height) visH=\(scroll.contentSize.height) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
                try? txt.write(toFile: "/tmp/peaky-shelf.txt", atomically: true, encoding: .utf8)
            }
        case "askallow", "askdeny": m?.status?.ask?.answer(allow: cmd == "askallow")
        case "shelf": m?.expand(tab: .shelf)
        case "collapse": m?.collapse()
        case "track": controllers.forEach { $0.startTracking() }
        case "fakein": controllers.forEach { $0.fakeMouse = $0.notchCentre; $0.startTracking() }
        case "fakeout": controllers.forEach { $0.fakeMouse = CGPoint(x: $0.notchCentre.x, y: $0.notchCentre.y - 400) }
        case "state":
            let lines = controllers.map { $0.debugState }.joined(separator: "\n")
            try? (lines + "\n").write(toFile: "/tmp/peaky-state.txt", atomically: true, encoding: .utf8)
        case "hoverexpand":
            withAnimation(IslandModel.spring) { m?.hovering = true }
            m?.expand()
        case "hoveron": withAnimation(IslandModel.spring) { m?.hovering = true }
        case "hoveroff": withAnimation(IslandModel.spring) { m?.hovering = false }
        case "evA":   // inside event, then force the window to lay out + display + flush
            pendingDebug = { [weak self] in m?.expand(); self?.controllers.forEach { $0.debugForceRedraw() } }
            postWake()
        case "evB":   // inside event, hop to the main queue
            pendingDebug = { DispatchQueue.main.async { m?.expand() } }
            postWake()
        case "evC":   // inside event, schedule on the run loop in common modes
            pendingDebug = { RunLoop.main.perform(inModes: [.common]) { m?.expand() } }
            postWake()
        case "evD":   // inside event, bounce through a distributed notification to ourselves
            pendingDebug = { DistributedNotificationCenter.default().postNotificationName(.init("io.github.iamsumanp.peaky.debug"), object: "expand", deliverImmediately: true) }
            postWake()
        case "evE":   // inside event, short delay on the main queue
            pendingDebug = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { m?.expand() } }
            postWake()
        case "darwin":  // no event at all: Darwin notification to ourselves
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("io.github.iamsumanp.peaky.darwintest" as CFString), nil, nil, true)
        case "evTwo":   // hover path as it is today: two separate changes inside the event
            pendingDebug = { withAnimation(IslandModel.spring) { m?.hovering = true }; m?.expand() }
            postWake()
        case "evOne":   // one combined change inside the event
            pendingDebug = { m?.hoverOpen(true, hovering: true) }
            postWake()
        case "evexpand":
            // expand from inside a posted application-defined event (the hover path)
            pendingDebug = { m?.expand() }
            postWake()
        case "fakesoon": Services.shared.calendar.debugFake(title: "Design Review", startsIn: 10 * 60 - 5, length: 30 * 60)
        case "fakenext": Services.shared.calendar.debugFakeNext()
        case "fakenow": Services.shared.calendar.debugFake(title: "Weekly Product Sync", startsIn: -10 * 60, length: 72 * 60)
        case "settings": openSettings()
        case "menudump":
            let m = NSMenu(); menuNeedsUpdate(m)
            let lines = m.items.map { $0.isSeparatorItem ? "────" : ($0.state == .on ? "✓ " : "  ") + $0.title }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: "/tmp/peaky-menu.txt", atomically: true, encoding: .utf8)
        case "awakeon": Services.shared.awake.start(for: 3600)
        case "awakeoff": Services.shared.awake.stop()
        case "menu":
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.statusItem?.menu?.cancelTracking() }
            statusItem?.button?.performClick(nil)
        case "askcal": Services.shared.calendar.requestAccess()
        case "expandall": controllers.forEach { $0.model.expand(tab: .home) }
        case "collapseall": controllers.forEach { $0.model.collapse() }
        case "nomusic": controllers.forEach { $0.model.debugSetMusic(false) }
        case "music": controllers.forEach { $0.model.debugSetMusic(true) }
        case "fakeset": controllers.forEach { $0.fakeMouse = $0.notchCentre }
        case "grab": controllers.forEach { $0.debugGrab(true) }
        case "release": controllers.forEach { $0.debugGrab(false) }
        case "fakeoff": controllers.forEach { $0.fakeMouse = nil }
        case "cycle":
            m?.expand(tab: .home)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { m?.collapse() }
        case "volume": IslandHub.post(.hud(HUDState(kind: .volume, value: 0.62, muted: false)))
        case "brightness": IslandHub.post(.hud(HUDState(kind: .brightness, value: 0.4, muted: false)))
        case "charging": IslandHub.post(.notice(Notice(key: "power", symbol: "bolt.fill", tint: Theme.level, title: "Charging",
                                                       detail: "76%", detailTint: Theme.level)))
        case "airpods": IslandHub.post(.notice(Notice(key: "bt-test", symbol: "airpodspro", tint: .white, title: "AirPods Pro",
                                                      detail: "100%", detailTint: Theme.level)))
        case "join": IslandHub.post(.notice(Notice(key: "cal-test", symbol: "video.fill", tint: .blue, title: "Daily Standup",
                                                   detail: "Join", detailTint: .white, duration: 6, pill: true)))
        case "pet": UserDefaults.standard.set("cat", forKey: Prefs.Key.pet.rawValue)
        case "dog": UserDefaults.standard.set("dog", forKey: Prefs.Key.pet.rawValue)
        case "bunny": UserDefaults.standard.set("bunny", forKey: Prefs.Key.pet.rawValue)
        case "nopet": UserDefaults.standard.set("none", forKey: Prefs.Key.pet.rawValue)
        default: break
        }
    }


    @objc private func openIsland() {
        controllers.first?.model.expand()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Peaky Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @StateObject private var displays = DisplayList()
    @AppStorage(Prefs.Key.openOnHover.rawValue) private var openOnHover = true
    @AppStorage(Prefs.Key.pet.rawValue) private var pet = "none"
    @AppStorage(Prefs.Key.awakeDisplay.rawValue) private var awakeDisplay = true
    @AppStorage(Prefs.Key.awakeDefault.rawValue) private var awakeDefault = 0.0
    @AppStorage(Prefs.Key.awakeAtLaunch.rawValue) private var awakeAtLaunch = false
    @AppStorage(Prefs.Key.showMusicActivity.rawValue) private var showMusic = true
    @AppStorage(Prefs.Key.showHUD.rawValue) private var showHUD = true
    @AppStorage(Prefs.Key.hudReplace.rawValue) private var hudReplace = false
    @AppStorage(Prefs.Key.notifyCharging.rawValue) private var notifyCharging = true
    @AppStorage(Prefs.Key.notifyBluetooth.rawValue) private var notifyBluetooth = true
    @AppStorage(Prefs.Key.notifyCalendar.rawValue) private var notifyCalendar = true
    @AppStorage(Prefs.Key.claudeWaitSeconds.rawValue) private var claudeWait = 120.0
    @AppStorage(Prefs.Key.claudeNotchApprove.rawValue) private var claudeApprove = true
    @AppStorage(Prefs.Key.claudeQuietWhenFront.rawValue) private var claudeQuiet = true
    @AppStorage(Prefs.Key.hideFromCapture.rawValue) private var hideFromCapture = true
    @AppStorage(Prefs.Key.claudeShowWorking.rawValue) private var claudeWorking = true
    @AppStorage(Prefs.Key.shelfExpireHours.rawValue) private var shelfExpire = 0.0

    @ObservedObject private var cal = Services.shared.calendar
    @State private var trusted = MediaKeyTap.trusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(displays.screens, id: \.info.id) { item in
                    Toggle(isOn: displays.binding(item.screen)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.info.name)
                            Text(item.info.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if Displays.isEnabled(item.screen) {
                        Toggle("Over full-screen apps", isOn: displays.fullscreenBinding(item.screen))
                            .font(.callout)
                            .padding(.leading, 16)
                    }
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Monitors without a notch get a small virtual one. With “Over full-screen apps” off for a monitor, the island hides there while a full-screen app is showing and comes back when you leave it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Default duration", selection: $awakeDefault) {
                    ForEach(KeepAwake.choices, id: \.label) { c in Text(c.label).tag(c.seconds ?? 0) }
                }
                Toggle("Keep the display on too", isOn: $awakeDisplay)
                    .onChange(of: awakeDisplay) { Services.shared.awake.refreshKind() }
                Toggle("Turn on when Peaky starts", isOn: $awakeAtLaunch)
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("Like Caffeine: stops your Mac from sleeping. Toggle it with the ☕ in the open island (right-click for durations) or from the menu bar icon. A small white mug sits beside the notch while it's on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Remove files from the shelf", selection: $shelfExpire) {
                    Text("Never").tag(0.0)
                    Text("After 1 hour").tag(1.0)
                    Text("After 4 hours").tag(4.0)
                    Text("After 1 day").tag(24.0)
                    Text("After 1 week").tag(168.0)
                }
                .onChange(of: shelfExpire) { Services.shared.shelf.prune() }
            } header: {
                Text("Shelf")
            } footer: {
                Text("Each file goes that long after you dropped it. Only off the shelf — the files themselves stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Island") {
                Toggle("Open instantly on hover (otherwise click)", isOn: $openOnHover)
                Toggle("Show music as a live activity", isOn: $showMusic)
                Toggle("Hide Peaky from screen sharing", isOn: $hideFromCapture)
                    .onChange(of: hideFromCapture) { NotchPanel.applyCapturePrivacy() }
                    .help("When you share your screen (Meet, Zoom, Teams…) or record it, the island isn't in the picture, so nobody sees your Claude alerts, meeting titles or shelf. Your own screenshots skip it too.")
            }

            Section {
                Picker("Pet", selection: $pet) {
                    ForEach(PetKind.allCases) { Text($0.name).tag($0.rawValue) }
                }
            } header: {
                Text("Pet")
            } footer: {
                Text("Sits beside the notch only while nothing else is showing. It naps if you leave it alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show volume changes in the notch", isOn: $showHUD)
                Toggle("Replace the system volume & brightness HUD", isOn: $hudReplace)
                    .onChange(of: hudReplace) {
                        if hudReplace && !MediaKeyTap.trusted { MediaKeyTap.requestTrust() }
                        Services.shared.applyPrefs()
                    }
                if hudReplace && !trusted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Needs Accessibility permission.").font(.callout)
                        Spacer()
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } header: {
                Text("HUD")
            } footer: {
                Text("Replacing the HUD lets Peaky take over the volume and brightness keys. Shift-Option + key steps in quarters.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Charging & low battery", isOn: $notifyCharging)
                Toggle("Bluetooth devices (AirPods…)", isOn: $notifyBluetooth)
                Toggle("Meetings 5 minutes before they start", isOn: $notifyCalendar)
                HStack {
                    Text("Calendar")
                    Spacer()
                    if cal.authorized {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if cal.denied {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    } else {
                        Button("Connect") { cal.requestAccess() }
                    }
                }
            }

            Section("Claude Code") {
                ClaudeHooksRow()
                Picker("“Needs permission” stays", selection: $claudeWait) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                    Text("Until handled").tag(3600.0)
                }
                Toggle("Show while Claude is working", isOn: $claudeWorking)
                    .help("“Claude · my-app · working 4m” (just Claude's spark when collapsed) while a session runs; it turns into Finished when done.")
                Toggle("Stay quiet while Claude's app is in front", isOn: $claudeQuiet)
                    .help("No Claude alerts while you're looking at the app the session runs in (the Claude app, that Terminal, that editor). If you switch away while Claude still needs you, it shows up in the notch then.")
                Toggle("Allow / Deny Claude from the notch", isOn: $claudeApprove)
                    .help("For Claude in the Claude app: approve or refuse a permission request from the open island. Claude's own prompt still works too; whichever you answer first counts.")
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Peaky: launch at login failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                UpdateRow()
                HStack {
                    Text("Gestures: click or swipe down to open, swipe up to close, two-finger swipe sideways to skip tracks.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 660)
        .onReceive(poll) { _ in trusted = MediaKeyTap.trusted }
    }
}

// MARK: - CLI alerts

extension Notice {
    /// Payload from tools/peaky-cli.swift: {"title", "detail", "symbol", "tint", "duration", "open", "key"}.
    init?(cliJSON: String) {
        guard let data = cliJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = o["title"] as? String, !title.isEmpty else { return nil }
        let tint = Notice.color(o["tint"] as? String)
        self.init(key: o["key"] as? String, symbol: o["symbol"] as? String ?? "bell.fill", tint: tint, title: title,
                  detail: o["detail"] as? String, detailTint: tint == .white ? .white.opacity(0.6) : tint,
                  duration: min(max(o["duration"] as? Double ?? 3.5, 1), 30))
        priority = o["priority"] as? Int ?? 0
        if (o["kind"] as? String) == "wait" {
            // e.g. Claude waiting for permission: stays until handled or the chosen time runs out.
            let secs = UserDefaults.standard.double(forKey: Prefs.Key.claudeWaitSeconds.rawValue)
            duration = secs > 0 ? secs : 120
            sticky = true
        }
        if let open = o["open"] as? String, !open.isEmpty {
            openURL = open.contains("://") ? URL(string: open)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: open)
        }
        if let f = o["focus"] as? [String: Any] {
            focus = SessionFocus(app: f["app"] as? String, tty: f["tty"] as? String, cwd: f["cwd"] as? String)
        }
        if let a = o["ask"] as? [String: Any], let id = a["id"] as? String, let key {
            ask = ClaudeAsk(id: id, key: key, tool: a["tool"] as? String ?? "", summary: a["summary"] as? String ?? "")
        }
    }

    static func color(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "red": return .red
        case "green": return Theme.level
        case "amber", "accent": return Theme.accent
        case "blue": return .blue
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return .gray
        case "claude": return Color(hex: 0xD97757)
        case let s? where s.hasPrefix("#") && s.count == 7:
            return UInt32(s.dropFirst(), radix: 16).map { Color(hex: $0) } ?? .white
        default: return .white
        }
    }
}
