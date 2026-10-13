import AppKit
import CoreBluetooth
import EventKit
import IOBluetooth
import IOKit.ps
import SwiftUI

// MARK: - Battery

final class BatteryService: ObservableObject {
    @Published private(set) var percent = 100
    @Published private(set) var charging = false
    @Published private(set) var onAC = true
    @Published private(set) var hasBattery = false

    private var source: CFRunLoopSource?
    private var started = false
    private var warnedAt: Set<Int> = []

    func start() {
        refresh()
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<BatteryService>.fromOpaque(ctx!).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    var symbol: String {
        if charging || onAC { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var tint: Color {
        if onAC { return Theme.level }
        return percent <= 20 ? .red : .white
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let newPercent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            let newAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let newCharging = d[kIOPSIsChargingKey] as? Bool ?? false

            if started {
                if newAC && !onAC, Prefs.bool(.notifyCharging) {
                    IslandHub.post(.notice(Notice(key: "power", symbol: "bolt.fill", tint: Theme.level, title: "Charging",
                                                  detail: "\(newPercent)%", detailTint: Theme.level)))
                }
                for threshold in [20, 10] where !newAC && newPercent <= threshold && !warnedAt.contains(threshold) {
                    warnedAt.insert(threshold)
                    IslandHub.post(.notice(Notice(key: "power", symbol: "battery.25percent", tint: .red, title: "Low Battery",
                                                  detail: "\(newPercent)%", detailTint: .red, duration: 4)))
                }
            }
            if newAC { warnedAt.removeAll() }

            hasBattery = true
            percent = newPercent
            onAC = newAC
            charging = newCharging
        }
    }
}

// MARK: - Bluetooth

/// AirPods show up as more than one Bluetooth device (the audio link plus a "… - Find My" one), connect in
/// stages and flap during handoff, so raw IOBluetooth events come in bursts. Devices are grouped by their
/// cleaned-up name, each group settles for a moment, and only a real change is announced — once.
final class BluetoothService: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var devices: [String: IOBluetoothDevice] = [:]   // address → device
    private var announced: [String: Bool] = [:]              // group → last state shown
    private var pending: [String: DispatchWorkItem] = [:]
    private var registeredAt = Date()

    /// IOBluetooth blocks the calling thread until the Bluetooth permission prompt is answered, which froze
    /// the whole app on launch. Ask through CoreBluetooth instead (non-blocking) and only register once allowed.
    func start() {
        switch CBManager.authorization {
        case .allowedAlways:
            register()
        case .notDetermined:
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        default:
            break // denied: Bluetooth alerts stay off
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBManager.authorization == .allowedAlways { register() }
    }

    private func register() {
        guard connectNote == nil else { return }
        registeredAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let addr = device.addressString else { return }
        devices[addr] = device
        if disconnectNotes[addr] == nil {
            disconnectNotes[addr] = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        }
        // The registration replays devices that were already connected; record them silently.
        if Date().timeIntervalSince(registeredAt) < 4 {
            announced[Self.group(device)] = true
            return
        }
        settle(Self.group(device))
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let addr = device.addressString else { return }
        note.unregister()
        disconnectNotes[addr] = nil
        settle(Self.group(device))
    }

    private func settle(_ group: String) {
        pending[group]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[group] = nil
            let members = self.devices.values.filter { Self.group($0) == group }
            guard let any = members.first(where: { !Self.isFindMy($0) }) ?? members.first else { return }
            let connected = members.contains { $0.isConnected() }
            guard self.announced[group] != connected else { return } // dropped and came straight back
            self.announced[group] = connected
            guard Prefs.bool(.notifyBluetooth) else { return }
            let title = Self.shortName(any)
            let symbol = Self.symbol(for: any)
            DispatchQueue.global(qos: .userInitiated).async {
                let battery = connected ? Self.batteryLevel(named: title) : nil
                DispatchQueue.main.async {
                    IslandHub.post(.notice(Notice(key: "bt-" + group, symbol: symbol, tint: .white, title: title,
                                                  detail: connected ? (battery.map { "\($0)%" } ?? "Connected") : "Disconnected",
                                                  detailTint: connected ? Theme.level : .white.opacity(0.5))))
                }
            }
        }
        pending[group] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private static func isFindMy(_ d: IOBluetoothDevice) -> Bool {
        (d.name ?? "").localizedCaseInsensitiveContains("find my")
    }

    private static func group(_ d: IOBluetoothDevice) -> String { shortName(d).lowercased() }

    /// "Alex's AirPods Pro - Find My" → "AirPods Pro", so it fits beside the notch.
    static func shortName(_ device: IOBluetoothDevice) -> String {
        var name = device.name ?? "Bluetooth"
        if let r = name.range(of: " - ") ?? name.range(of: " – ") { name = String(name[..<r.lowerBound]) }
        if let r = name.range(of: "’s ") ?? name.range(of: "'s ") { name = String(name[r.upperBound...]) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Lowest earbud (or the single) battery level, from the same data System Information shows.
    private static func batteryLevel(named name: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["-json", "SPBluetoothDataType"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bt = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bt["device_connected"] as? [[String: Any]] else { return nil }
        for entry in connected {
            for (devName, info) in entry where devName.localizedCaseInsensitiveContains(name) {
                guard let info = info as? [String: Any] else { continue }
                let levels = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelMain"]
                    .compactMap { (info[$0] as? String)?.replacingOccurrences(of: "%", with: "") }
                    .compactMap(Int.init)
                if let m = levels.min() { return m }
            }
        }
        return nil
    }

    static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        if name.contains("keyboard") { return "keyboard" }
        if name.contains("mouse") { return "magicmouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        switch device.deviceClassMajor {
        case 0x04: return "headphones" // audio/video
        case 0x05: return "keyboard"   // peripheral
        case 0x02: return "iphone"     // phone
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Calendar

struct CalEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    /// Video-call link found in the event (Meet, Zoom, Teams, Webex…).
    let joinURL: URL?

    /// From 15 minutes before the start until it ends, the meeting can be joined from the island.
    var joinableNow: Bool {
        joinURL != nil && soonOrNow
    }

    /// Timed event starting within 15 minutes, or in progress.
    var soonOrNow: Bool {
        !allDay && start.timeIntervalSinceNow < 15 * 60 && end > Date()
    }

    var isNow: Bool { start <= Date() && end > Date() }

    /// "in 10 mins" before it starts, "1 hr 2 mins left" while it runs.
    var relative: String {
        isNow ? Self.span(end.timeIntervalSinceNow) + " left" : "in " + Self.span(start.timeIntervalSinceNow)
    }

    /// 62 min → "1 hr 2 mins", 10 → "10 mins", 1 → "1 min", 120 → "2 hrs".
    static func span(_ seconds: TimeInterval) -> String {
        let m = max(1, Int((seconds / 60).rounded(.up)))
        if m < 60 { return "\(m) min" + (m == 1 ? "" : "s") }
        let h = m / 60, r = m % 60
        let hs = "\(h) hr" + (h == 1 ? "" : "s")
        return r == 0 ? hs : "\(hs) \(r) min" + (r == 1 ? "" : "s")
    }
}

final class CalendarService: ObservableObject {
    @Published private(set) var events: [CalEvent] = []
    /// Everything today, including meetings that already ended (for the menu bar list).
    @Published private(set) var today: [CalEvent] = []
    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var announcedSoon: Set<String> = []
    private var announcedJoin: Set<String> = []

    /// The meeting to offer a Join button for, if any.
    var joinable: CalEvent? { events.first { $0.joinableNow } }

    /// Debug: pretend there is a meeting `startsIn` seconds from now lasting `length` seconds.
    func debugFake(title: String, startsIn: TimeInterval, length: TimeInterval) {
        let s = Date().addingTimeInterval(startsIn)
        events = [CalEvent(id: "debug", title: title, start: s, end: s.addingTimeInterval(length), allDay: false,
                           color: .teal, joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))]
    }

    /// Debug: a meeting that ended 2 minutes ago and "Standup" in 25 minutes.
    func debugFakeNext() {
        let now = Date()
        let done = CalEvent(id: "debug-done", title: "Design Review", start: now.addingTimeInterval(-1800),
                            end: now.addingTimeInterval(-120), allDay: false, color: .teal, joinURL: nil)
        let next = CalEvent(id: "debug-next", title: "Standup", start: now.addingTimeInterval(25 * 60),
                            end: now.addingTimeInterval(40 * 60), allDay: false, color: .orange,
                            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        today = [done, next]
        events = [next]
    }

    /// The meeting shown beside the notch while idle: starting within 15 minutes, or in progress.
    var agenda: CalEvent? { events.first { $0.soonOrNow } }

    /// Right after a meeting ends: the next one ("Next: Standup · in 25 mins") instead of nothing. Shown all the
    /// way to its start when it's within the hour; otherwise just for 5 minutes after the last one ends.
    var upNext: CalEvent? { Self.upNext(today: today, upcoming: events, now: Date()) }

    static func upNext(today: [CalEvent], upcoming: [CalEvent], now: Date) -> CalEvent? {
        guard let last = today.filter({ !$0.allDay && $0.end <= now }).max(by: { $0.end < $1.end }),
              let next = upcoming.first(where: { !$0.allDay && $0.start > now }),
              Calendar.current.isDate(next.start, inSameDayAs: now) else { return nil }
        return next.start.timeIntervalSince(last.end) <= 3600 || now.timeIntervalSince(last.end) < 300 ? next : nil
    }

    func start() {
        checkAccess(attempt: 0)
    }

    /// Right after a rebuild macOS can briefly report "not decided" for an access it already granted,
    /// which showed "Connect Calendar" for no reason. Keep re-checking for a minute before believing it.
    private func checkAccess(attempt: Int) {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        denied = status == .denied || status == .restricted
        if authorized {
            if timer == nil { begin() }
            return
        }
        guard attempt < 12, !denied else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkAccess(attempt: attempt + 1) }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.denied = !granted
                if granted { self?.begin() }
            }
        }
    }

    private func begin() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        reload()
    }

    private func reload() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let now = Date()
        let all = store.events(matching: pred)
            .filter { $0.status != .canceled && !Self.declined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { e in
                CalEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
                         title: e.title ?? "Untitled", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                         color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                         joinURL: Self.meetingLink(in: e))
            }
        events = all.filter { $0.end > now }
        let todayEnd = cal.date(byAdding: .day, value: 1, to: start) ?? end
        today = all.filter { $0.start < todayEnd && $0.end > start }
        tick()
    }

    private static let meetingPattern = try! NSRegularExpression(pattern:
        #"https://(?:[\w-]+\.)?(?:meet\.google\.com/[a-z0-9-]+|zoom\.us/(?:j|my|w)/[^\s<>"]+|teams\.microsoft\.com/l/meetup-join/[^\s<>"]+|teams\.live\.com/meet/[^\s<>"]+|[\w-]+\.webex\.com/[^\s<>"]+|meet\.jit\.si/[^\s<>"]+|app\.slack\.com/huddle/[^\s<>"]+)"#,
        options: [.caseInsensitive])

    /// Looks in the event's URL, location and notes, the places calendar invites put the call link.
    static func meetingLink(in e: EKEvent) -> URL? {
        for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = meetingPattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ">)].,")))
            }
        }
        return nil
    }

    /// Meetings you said no to don't count (like MeetingBar's default).
    static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    func join(_ e: CalEvent) {
        if let u = e.joinURL { NSWorkspace.shared.open(u) }
    }

    /// Five minutes out: a heads-up. One minute out: a Join pill for meetings with a call link.
    private func tick() {
        let now = Date()
        events.removeAll { $0.end <= now }
        objectWillChange.send() // joinable windows move with the clock
        guard Prefs.bool(.notifyCalendar) else { return }
        for e in events where !e.allDay {
            let mins = e.start.timeIntervalSince(now) / 60
            if let url = e.joinURL, mins <= 1.1, mins > -5, !announcedJoin.contains(e.id) {
                announcedJoin.insert(e.id)
                announcedSoon.insert(e.id)
                IslandHub.post(.notice(Notice(key: "cal-" + e.id, symbol: "video.fill", tint: e.color, title: e.title,
                                              detail: "Join", detailTint: .white, duration: 25,
                                              openURL: url, pill: true)))
            } else if mins <= 5, mins > 1.1, !announcedSoon.contains(e.id) {
                announcedSoon.insert(e.id)
                IslandHub.post(.notice(Notice(key: "cal-" + e.id, symbol: "calendar", tint: e.color, title: e.title,
                                              detail: "In \(Int(mins.rounded(.up))) min", duration: 5,
                                              openURL: e.joinURL)))
            } else if e.joinURL == nil, mins <= 0.5, mins > -1, !announcedJoin.contains(e.id) {
                announcedJoin.insert(e.id)
                IslandHub.post(.notice(Notice(key: "cal-" + e.id, symbol: "calendar", tint: e.color, title: e.title,
                                              detail: "Starting now", duration: 5)))
            }
        }
    }
}

// MARK: - Shelf

/// Files dropped on the notch. Stores references (paths), never copies.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let key = "shelf.paths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(u) { items.append(u) }
        save()
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}
