import AppKit
import Combine
import SwiftUI

// MARK: - Events shown in the island

enum HUDKind: Equatable { case volume, brightness }

struct HUDState: Equatable {
    var kind: HUDKind
    var value: Float
    var muted: Bool
}

/// A one-line alert: symbol + title on the left of the notch, detail on the right.
struct Notice: Equatable {
    var id = UUID()
    /// Notices with the same key replace each other instead of queueing (e.g. one per Bluetooth device).
    var key: String? = nil
    var symbol: String
    var tint: Color
    var title: String
    var detail: String? = nil
    var detailTint: Color = .white.opacity(0.6)
    var duration: TimeInterval = 2.6
    /// Clicking the notice opens this (a meeting link, the app Claude Code runs in…).
    var openURL: URL? = nil
    /// Draw the detail as a tappable pill (e.g. "Join").
    var pill = false
    /// Long-lived (e.g. Claude waiting for permission): other notices may interrupt it briefly,
    /// after which it comes back for the rest of its time.
    var sticky = false
    var expiresAt: Date? = nil
    /// Higher shows first: Claude alerts (1) jump ahead of everything else and aren't interrupted by
    /// ordinary ones (0) like AirPods, which wait their turn instead.
    var priority = 0
    /// Claude asking for permission, answerable from the notch.
    var ask: ClaudeAsk? = nil
    /// Where clicking it takes you (the Claude session's terminal tab / window / app).
    var focus: SessionFocus? = nil
    /// Clicking shows this file in Finder (e.g. a finished download).
    var revealURL: URL? = nil
}

enum Transient: Equatable {
    case hud(HUDState)
    case notice(Notice)
    /// Remove any notice with this key (shown or queued).
    case clear(String)
}

/// Fan-out for HUDs and notices to every island (one per screen).
enum IslandHub {
    static let events = PassthroughSubject<Transient, Never>()
    static func post(_ t: Transient) {
        if Thread.isMainThread { events.send(t) } else { DispatchQueue.main.async { events.send(t) } }
    }
}

enum IslandTab: Equatable { case home, shelf }

/// What the island is showing right now, highest priority first.
enum Presentation: Equatable { case expanded, notice, hud, peek, music, status, pet, idle }

/// The one important thing shown left of the notch between alerts (even while music plays).
struct StatusItem: Equatable {
    enum Kind: Equatable { case claude, download, meeting, awake }
    let kind: Kind
    let title: String
    let detail: String
    let tint: Color
    /// Meetings get their calendar colour bar; Claude gets its icon.
    let bar: Color?
    let symbol: String?
    /// What the Join / Open button does.
    let openURL: URL?
    let actionLabel: String?
    var ask: ClaudeAsk? = nil
    var focus: SessionFocus? = nil

    /// Longer for Claude, so "Claude · project" fits.
    var titleMax: CGFloat { kind == .claude ? 132 : IslandModel.agendaTitleMax }

    /// The Open / Join button and clicking the title.
    func open() {
        if let focus { focus.go() } else if let openURL { NSWorkspace.shared.open(openURL) }
    }
}

// MARK: - Geometry

struct NotchGeometry {
    let screenFrame: CGRect
    let hasNotch: Bool
    /// Size of the hardware notch (or a virtual one on screens without).
    let notch: CGSize
    /// True when the notch is drawn by Peaky (a monitor without one), false for the MacBook's real notch.
    let isVirtual: Bool

    init(screen: NSScreen) {
        screenFrame = screen.frame
        // Monitors without a notch get a virtual one, the same size as the MacBook's, so the island looks
        // and behaves exactly the same everywhere.
        hasNotch = true
        if let real = Self.realNotch(screen) {
            notch = real
            isVirtual = false
        } else {
            // Compact: about menu-bar height, so it barely covers anything (in full-screen apps the
            // external monitor has no menu bar and the notch sits on the app itself).
            notch = CGSize(width: 120, height: 24)
            isVirtual = true
        }
    }

    private static func realNotch(_ screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}

// MARK: - Model

final class IslandModel: ObservableObject {
    /// One critically-damped-ish spring for everything, so every change feels the same.
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.88)
    static let close = Animation.spring(response: 0.32, dampingFraction: 0.95)
    /// Opening is quicker than everything else so it feels instant under the cursor.
    static let open = Animation.spring(response: 0.28, dampingFraction: 0.84)

    static let petEar: CGFloat = 32

    let geo: NotchGeometry

    // @Published announces a change *before* the value is stored (willSet). Hover changed two values in a
    // row, SwiftUI re-read the view during the second announcement, saw the old "closed" value and never
    // looked again — the island stayed closed until something else changed (you leaving). So every
    // state change also bumps `revision` *after* the value is stored; that last announcement guarantees
    // SwiftUI's final read sees the final state.
    @Published private(set) var revision = 0
    @Published private(set) var expanded = false { didSet { revision &+= 1 } }
    @Published var hovering = false { didSet { revision &+= 1 } }
    @Published var tab: IslandTab = .home { didSet { revision &+= 1 } }
    @Published private(set) var hud: HUDState? { didSet { if let hud { lastHUD = hud }; revision &+= 1 } }
    @Published private(set) var notice: Notice? { didSet { if let notice { lastNotice = notice }; revision &+= 1 } }
    /// What the HUD / notice layers draw; kept after dismissal so they fade out rather than blink.
    private(set) var lastHUD: HUDState?
    private(set) var lastNotice: Notice?
    @Published private(set) var musicActive = false { didSet { revision &+= 1 } }
    @Published private(set) var pet: PetKind = .none { didSet { revision &+= 1 } }
    @Published var dropTargeted = false { didSet { revision &+= 1 } }
    /// Files on the shelf — the open island grows a row at a time to show them.
    @Published private(set) var shelfCount = 0 { didSet { revision &+= 1 } }
    /// The open player shows a progress bar when the track has a length (not for live streams).
    @Published private(set) var showsScrubber = false { didSet { revision &+= 1 } }
    static let scrubberHeight: CGFloat = 22
    /// The app in front. Claude alerts stay out of the way while you're already looking at Claude's app.
    @Published private(set) var frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        didSet { revision &+= 1 }
    }

    /// Is this alert's Claude session in the app you're looking at right now?
    func lookingAt(_ n: Notice?) -> Bool {
        guard Prefs.bool(.claudeQuietWhenFront), let app = n?.focus?.app else { return false }
        return app == frontApp
    }
    /// Downloads in progress, shown beside the notch until they finish.
    @Published private(set) var downloads: [DownloadsMonitor.Item] = [] { didSet { revision &+= 1 } }
    /// Meeting shown left of the notch while idle (15 min before → end), and its "in 10 mins" text.
    @Published private(set) var agenda: CalEvent? { didSet { revision &+= 1 } }
    @Published private(set) var agendaText = "" { didSet { revision &+= 1 } }
    /// Claude waiting for you: pops up as a notice, then lives in the left slot until handled.
    @Published private(set) var claudeWaiting: Notice? { didSet { revision &+= 1 } }
    /// Keep-awake on: a small cup rides at the right end of every compact state.
    @Published private(set) var caffeinated = false { didSet { revision &+= 1 } }
    static let cupWidth: CGFloat = 26
    var cup: CGFloat { caffeinated ? Self.cupWidth : 0 }
    private var claudeWaitTimer: Timer?

    /// Left-slot priority: Claude needs you > a download in progress > meeting (15 min before → end).
    var status: StatusItem? {
        if let c = claudeWaiting, !lookingAt(c) {
            return StatusItem(kind: .claude, title: c.title, detail: c.detail ?? "Needs you", tint: c.tint,
                              bar: nil, symbol: c.symbol, openURL: c.openURL,
                              actionLabel: c.openURL == nil && c.focus == nil ? nil : "Open", ask: c.ask, focus: c.focus)
        }
        if !downloads.isEmpty {
            let fractions = downloads.compactMap(\.fraction)
            let pct = fractions.isEmpty ? nil : Int(fractions.reduce(0, +) / Double(fractions.count) * 100)
            return StatusItem(kind: .download,
                              title: downloads.count == 1 ? downloads[0].name : "\(downloads.count) downloads",
                              detail: pct.map { "\($0)%" } ?? "Downloading", tint: .white.opacity(0.7), bar: nil,
                              symbol: "arrow.down", openURL: nil, actionLabel: nil)
        }
        if let e = agenda {
            // Not within 15 minutes yet = shown because the previous meeting just ended.
            let next = !e.soonOrNow
            return StatusItem(kind: .meeting, title: next ? "Next: " + e.title : e.title, detail: agendaText,
                              tint: e.isNow ? Theme.accent : .white.opacity(0.6), bar: e.color, symbol: nil,
                              openURL: e.joinURL, actionLabel: e.joinURL == nil ? nil : "Join")
        }
        // Keep Awake takes the left side only when it's free (music puts its artwork there) and a pet
        // holds the right; with no pet, the mug simply sits in the pet's place on the right instead.
        let awake = Services.shared.awake
        if awake.active, !musicActive, pet != .none {
            return StatusItem(kind: .awake, title: "Awake", detail: awake.until == nil ? "∞" : awake.remainingShort,
                              tint: Theme.accent, bar: nil, symbol: nil, openURL: nil, actionLabel: nil)
        }
        return nil
    }

    /// The status gets its own line in the peek / open panel — except a meeting in the idle panel,
    /// which already lists it.
    var showsStatusLine: Bool {
        guard let s = status, s.kind != .awake else { return false }
        return s.kind == .claude || Services.shared.nowPlaying.hasMedia
    }

    private func setClaudeWaiting(_ n: Notice?) {
        claudeWaitTimer?.invalidate()
        withAnimation(Self.spring) { claudeWaiting = n }
        guard let n else { return }
        claudeWaitTimer = Timer.scheduledTimer(withTimeInterval: max(1, n.duration), repeats: false) { [weak self] _ in
            self?.setClaudeWaiting(nil)
        }
    }

    private var hudTimer: Timer?
    private var noticeTimer: Timer?
    private var musicHideWork: DispatchWorkItem?
    private var queue: [Notice] = []
    private var bag = Set<AnyCancellable>()

    init(geo: NotchGeometry) {
        self.geo = geo
        pet = Prefs.pet
        IslandHub.events.sink { [weak self] in self?.receive($0) }.store(in: &bag)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .sink { [weak self] id in self?.frontAppChanged(id) }
            .store(in: &bag)
        let player = Services.shared.nowPlaying
        player.$duration.combineLatest(player.$recentlyActive, player.$title)
            .map { d, active, title in d > 1 && active && !title.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in withAnimation(Self.spring) { self?.showsScrubber = on } }
            .store(in: &bag)
        Services.shared.shelf.$items.map(\.count).removeDuplicates()
            .sink { [weak self] n in self?.shelfCount = n }.store(in: &bag)
        Services.shared.downloads.$items.receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                if items.isEmpty != self.downloads.isEmpty {
                    withAnimation(Self.spring) { self.downloads = items }
                } else {
                    self.downloads = items
                }
            }
            .store(in: &bag)

        // Show the music activity as soon as something plays, but hold it through short pauses
        // so a quick pause/play (or AirPods switching) doesn't make the island jump.
        let np = Services.shared.nowPlaying
        np.$isPlaying.combineLatest(np.$title)
            .map { playing, title in playing && !title.isEmpty }
            .removeDuplicates()
            .sink { [weak self] playing in self?.musicPlaying(playing) }
            .store(in: &bag)

        Services.shared.awake.$active
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in withAnimation(Self.spring) { self?.caffeinated = on } }
            .store(in: &bag)
        // The "42m left" text ticks down.
        Services.shared.awake.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.revision &+= 1 }
            .store(in: &bag)

        // The calendar re-publishes every 15 s; refresh the idle meeting and its countdown text.
        Services.shared.calendar.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshAgenda() }
            .store(in: &bag)
        DispatchQueue.main.async { [weak self] in self?.refreshAgenda() }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.pet != Prefs.pet else { return }
                withAnimation(Self.spring) { self.pet = Prefs.pet }
            }
            .store(in: &bag)
    }

    private func frontAppChanged(_ id: String) {
        withAnimation(Self.spring) { frontApp = id }
        // Switched to the app a Claude popup is about: it has done its job.
        guard Prefs.bool(.claudeQuietWhenFront) else { return }
        queue.removeAll { $0.focus?.app == id }
        if notice?.focus?.app == id { endNotice(force: true) }
    }

    private func refreshAgenda() {
        let cal = Services.shared.calendar
        let e = cal.agenda ?? cal.upNext
        let text = e?.relative ?? ""
        guard e != agenda || text != agendaText else { return }
        withAnimation(Self.spring) {
            agenda = e
            agendaText = text
        }
    }

    private func musicPlaying(_ playing: Bool) {
        musicHideWork?.cancel()
        if playing {
            guard Prefs.bool(.showMusicActivity), !musicActive else { return }
            withAnimation(Self.spring) { musicActive = true }
        } else if musicActive {
            let w = DispatchWorkItem { [weak self] in
                withAnimation(Self.close) { self?.musicActive = false }
            }
            musicHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        }
    }

    var presentation: Presentation {
        if expanded { return .expanded }
        // Your own key press always answers right away, over music and over alerts; an alert carries on after.
        if hud != nil { return .hud }
        if notice != nil { return .notice }
        // With "Open instantly on hover" off, hovering music doesn't grow either; a click opens the player.
        if musicActive { return hovering && Prefs.bool(.openOnHover) ? .peek : .music }
        if status != nil { return .status }
        if pet != .none { return .pet }
        return .idle
    }

    // MARK: Sizing

    func size(for p: Presentation) -> CGSize {
        let n = geo.notch, h = n.height
        switch p {
        case .idle:
            // No pet, Keep Awake on: the mug sits in the pet's place.
            if geo.hasNotch { return CGSize(width: n.width + (hovering ? 8 : 0) + (caffeinated ? Self.petEar : 0),
                                            height: hovering ? h + 2 : h) }
            return CGSize(width: n.width, height: hovering ? h : 0)
        case .status:
            return CGSize(width: n.width + statusLeftEar + statusRightEar, height: h)
        case .pet:
            // The pet wears the coffee as a hat, so no extra cup slot here.
            return geo.hasNotch ? CGSize(width: n.width + Self.petEar, height: h) : CGSize(width: Self.petEar + 12, height: h)
        case .music:
            // With something important on the left, music keeps only its bars on the right.
            if status != nil { return CGSize(width: n.width + statusLeftEar + Self.musicRightEar(h) + cup, height: h) }
            return CGSize(width: n.width + Self.musicLeftEar(h) + Self.musicBarsEar + cup, height: h)
        case .peek:
            return CGSize(width: max(n.width + 230, geo.isVirtual ? 340 : 420),
                          height: h + 50 + (showsStatusLine ? statusLineH : 0))
        case .hud:
            return CGSize(width: n.width + Self.hudEar * 2, height: h)
        case .notice:
            return CGSize(width: n.width + Self.noticeEar(lastNotice) * 2, height: h)
        case .expanded:
            let w = max(n.width + 225, geo.isVirtual ? 360 : 420)
            if tab == .shelf, shelfCount > 0 {
                return CGSize(width: w, height: h + 6 + Self.shelfBarHeight + 6 + shelfGridHeight(width: w) + 14)
            }
            return CGSize(width: w, height: h + 76 + (showsStatusLine ? statusLineH : 0)
                                       + (tab == .home && showsScrubber ? Self.scrubberHeight : 0))
        }
    }

    // MARK: Shelf

    static let shelfTile = CGSize(width: 64, height: 56)
    static let shelfGap: CGFloat = 4
    static let shelfBarHeight: CGFloat = 22
    /// Up to this many rows show at once; the rest scroll.
    static let shelfMaxRows = 3

    func shelfColumns(width: CGFloat) -> Int {
        max(1, Int((width - 36 + Self.shelfGap) / (Self.shelfTile.width + Self.shelfGap)))
    }

    /// The file grid: as many rows as the files need, up to three.
    func shelfGridHeight(width: CGFloat) -> CGFloat {
        let cols = shelfColumns(width: width)
        let rows = min(Self.shelfMaxRows, max(1, (shelfCount + cols - 1) / cols))
        return CGFloat(rows) * Self.shelfTile.height + CGFloat(rows - 1) * Self.shelfGap
    }

    // MARK: Ear widths (the visible parts left and right of the hardware notch)

    /// Space between the hardware notch and the nearest content in the compact states: content hugs the
    /// notch, the outer padding keeps it clear of the rounded ends.
    static let innerGap: CGFloat = 6
    static func artSize(_ h: CGFloat) -> CGFloat { h - (h > 30 ? 14 : 8) }
    /// Music alone: artwork on the left, bars on the right.
    static func musicLeftEar(_ h: CGFloat) -> CGFloat { 10 + artSize(h) + innerGap }
    static let musicBarsEar: CGFloat = innerGap + 17 + 12
    /// Artwork + bars on the right when the left side shows a status.
    static func musicRightEar(_ h: CGFloat) -> CGFloat { innerGap + artSize(h) + 7 + 17 + 12 }
    static let hudEar: CGFloat = 78
    static let noticeTitleFont = Theme.nsTitle(12)
    static let noticeDetailFont = Theme.nsBody(11.5)

    /// Just wide enough for the notice's text on each side (icon + title left, detail right), so short
    /// alerts like "AirPods Pro · 100%" stay compact. Both ears match so the island stays centred.
    static func noticeEar(_ n: Notice?) -> CGFloat {
        guard let n else { return 100 }
        let title = (n.title as NSString).size(withAttributes: [.font: noticeTitleFont]).width
        let left = 12 + 18 + 7 + title + 8
        var right: CGFloat = 0
        if let d = n.detail {
            let w = (d as NSString).size(withAttributes: [.font: noticeDetailFont]).width
            right = (n.pill ? w + 20 : w) + 14 + 6 + (n.pill ? 0 : 0)
        }
        return min(max(left, right, 64), 130).rounded(.up)
    }

    /// The pet sits to the right of the notch (and the meeting to the left), so those states grow
    /// unevenly; shift the island so the hardware notch stays covered exactly.
    func xOffset(for p: Presentation) -> CGFloat {
        guard geo.hasNotch else { return 0 }
        switch p {
        case .idle: return caffeinated ? Self.petEar / 2 : 0
        case .pet: return Self.petEar / 2
        case .status: return (statusRightEar - statusLeftEar) / 2
        case .music:
            let h = geo.notch.height
            return status == nil ? (Self.musicBarsEar + cup - Self.musicLeftEar(h)) / 2
                                 : (Self.musicRightEar(h) + cup - statusLeftEar) / 2
        default: return 0
        }
    }

    static let agendaTitleFont = Theme.nsTitle(11)
    static let agendaDetailFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    static let agendaTitleMax: CGFloat = 86

    static let statusLineHeight: CGFloat = 30
    /// A permission request gets a second line (what Claude wants to run) and Allow / Deny.
    var statusLineH: CGFloat { status?.ask != nil ? 44 : Self.statusLineHeight }

    /// Meeting / Claude with the right side free (no music): title left of the notch, time right of it.
    var statusSplit: Bool {
        guard let s = status else { return false }
        return s.kind != .awake && !musicActive
    }

    /// Colour bar (or icon) + title — plus "· in 10 mins" when it isn't split to the right.
    var statusLeftEar: CGFloat {
        guard let s = status else { return 0 }
        // Same width as the pet's slot, so the mug and the pet sit symmetrically around the notch.
        if s.kind == .awake { return Self.petEar }
        let lead: CGFloat = s.symbol != nil ? 16 + 6 : 3 + 7
        let t = min((s.title as NSString).size(withAttributes: [.font: Self.agendaTitleFont]).width, s.titleMax)
        let d = statusSplit ? 0 : 5 + (("· " + s.detail) as NSString).size(withAttributes: [.font: Self.agendaDetailFont]).width
        return (12 + lead + t + d + Self.innerGap).rounded(.up)
    }

    /// Right of the notch: the time ("13 mins left") for a meeting / Claude — no pet then — or the pet
    /// beside the Keep Awake mug.
    var statusRightEar: CGFloat {
        guard let s = status else { return 0 }
        if s.kind == .awake { return pet != .none ? Self.petEar : 0 }
        let d = statusSplit ? (s.detail as NSString).size(withAttributes: [.font: Self.agendaDetailFont]).width + Self.innerGap + 12 : 0
        return (d + cup).rounded(.up)
    }

    func radii(for p: Presentation) -> (top: CGFloat, bottom: CGFloat) {
        switch p {
        case .idle, .music, .hud, .notice, .pet, .status: return (6, Theme.compactBottomRadius)
        case .peek: return (8, Theme.expandedBottomRadius)
        case .expanded: return (10, Theme.expandedBottomRadius)
        }
    }

    // MARK: State changes

    func expand(tab: IslandTab? = nil) {
        if let tab { self.tab = tab }
        guard !expanded else { return }
        withAnimation(Self.open) { expanded = true }
    }

    func collapse() {
        guard expanded, !ShelfCollectionView.quickLookVisible, !IslandMenu.isOpen else { return }
        NotchPanel.giveBackAll()
        withAnimation(Self.close) {
            expanded = false
            dropTargeted = false
        }
        // Next time it opens on the normal view; only a file drag (or the tray button) shows the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.expanded, self.tab != .home else { return }
            self.tab = .home
        }
    }

    func switchTab(forward: Bool) {
        withAnimation(Self.spring) { tab = (tab == .home) == forward ? .shelf : .home }
    }

    private func receive(_ t: Transient) {
        switch t {
        case .hud(let h):
            hudTimer?.invalidate()
            if hud == nil || hud?.kind != h.kind {
                withAnimation(Self.spring) { hud = h }
            } else {
                withAnimation(.easeOut(duration: 0.12)) { hud = h }
            }
            hudTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                withAnimation(Self.close) { self?.hud = nil }
            }
        case .clear(let key):
            if claudeWaiting?.key == key { setClaudeWaiting(nil) }
            queue.removeAll { $0.key == key }
            if notice?.key == key { endNotice(force: true) }
        case .notice(var n):
            if lookingAt(n) {
                // You're already in the app this Claude session runs in: no popup. A wait is still kept
                // (hidden) so it appears if you switch away before answering.
                if n.sticky {
                    if n.ask == nil, n.key == claudeWaiting?.key { n.ask = claudeWaiting?.ask }
                    setClaudeWaiting(n)
                } else if let key = n.key, key == claudeWaiting?.key {
                    setClaudeWaiting(nil)
                }
                return
            }
            if n.sticky, let key = n.key, claudeWaiting?.key == key {
                // Same wait already announced (PermissionRequest fires at once, Claude Code's Notification
                // ~6 s later): just keep the slot current, no second popup — and keep its Allow / Deny.
                if n.ask == nil { n.ask = claudeWaiting?.ask }
                setClaudeWaiting(n)
                return
            }
            if n.sticky {
                // Claude waiting: pop up for a few seconds, then live in the left slot until handled.
                setClaudeWaiting(n)
                n.sticky = false
                n.duration = 4
            } else if let key = n.key, key == claudeWaiting?.key {
                setClaudeWaiting(nil) // e.g. "Finished" for the same session
            }
            if n.sticky, n.expiresAt == nil { n.expiresAt = Date().addingTimeInterval(n.duration) }
            if let current = notice, n.key == nil || n.key != current.key,
               n.priority > current.priority || (current.sticky && n.priority >= current.priority) {
                // Let the newcomer through, then bring the sticky one back with its remaining time.
                var resume = current
                resume.duration = max(1, (current.expiresAt ?? Date()).timeIntervalSinceNow)
                queue.removeAll { $0.key != nil && $0.key == resume.key }
                queue.insert(resume, at: 0)
                show(n)
                return
            }
            if let key = n.key, notice?.key == key {
                // Same subject (e.g. the same AirPods): update in place, don't stack another popup.
                withAnimation(Self.spring) { notice = n }
                scheduleNoticeEnd(n.duration)
            } else if let key = n.key, let i = queue.firstIndex(where: { $0.key == key }) {
                queue[i] = n
            } else if notice == nil {
                show(n)
            } else {
                // Queue by priority, first-come within the same priority.
                let i = queue.firstIndex { $0.priority < n.priority } ?? queue.count
                queue.insert(n, at: i)
            }
        }
    }

    private func show(_ n: Notice) {
        withAnimation(Self.spring) { notice = n }
        let remaining = n.expiresAt.map { $0.timeIntervalSinceNow } ?? n.duration
        scheduleNoticeEnd(max(1, remaining))
    }

    private func scheduleNoticeEnd(_ after: TimeInterval) {
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            self?.endNotice()
        }
    }

    private func endNotice(force: Bool = false) {
        // Don't pull a notice away while the cursor is on it (e.g. reaching for Join).
        if !force, hovering, notice != nil {
            scheduleNoticeEnd(1)
            return
        }
        noticeTimer?.invalidate()
        withAnimation(Self.close) { notice = nil }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.show(next) }
    }

    /// Hover-open as ONE state change (one invalidation), instead of hovering-then-expanded.
    func hoverOpen(_ open: Bool, hovering h: Bool, tab: IslandTab? = nil) {
        if let tab { self.tab = tab }
        withAnimation(open ? Self.open : Self.spring) {
            hovering = h
            if open { expanded = true }
        }
    }

    func debugSetMusic(_ on: Bool) { withAnimation(Self.spring) { musicActive = on } }

    func dismissNotice() {
        if let f = notice?.focus { f.go() }
        else if let r = notice?.revealURL { NSWorkspace.shared.activateFileViewerSelecting([r]) }
        else if let url = notice?.openURL { NSWorkspace.shared.open(url) }
        noticeTimer?.invalidate()
        withAnimation(Self.close) { notice = nil }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.show(next) }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        dragLog("drop received (\(providers.count) items)")
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            DispatchQueue.main.async {
                guard !urls.isEmpty else { return }
                Services.shared.shelf.add(urls)
                self?.tab = .shelf
            }
        }
        return true
    }
}
