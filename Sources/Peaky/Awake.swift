import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Caffeine, built in: a power assertion that stops the Mac (and by default the display) from sleeping,
/// indefinitely or for a set time. No special permissions needed.
final class KeepAwake: ObservableObject {
    @Published private(set) var active = false
    /// When it switches itself off; nil while active means "indefinitely".
    @Published private(set) var until: Date?
    /// The duration last chosen (for the ✓ in the menu), whichever control started it.
    private(set) var chosenSeconds: TimeInterval?

    private var assertions: [IOPMAssertionID] = []
    private var expiry: Timer?
    private var ticker: Timer?

    /// Durations offered in menus (seconds; nil = indefinitely).
    static let choices: [(label: String, seconds: TimeInterval?)] = [
        ("Indefinitely", nil), ("15 minutes", 15 * 60), ("30 minutes", 30 * 60),
        ("1 hour", 3600), ("2 hours", 2 * 3600), ("5 hours", 5 * 3600),
    ]

    func start(for seconds: TimeInterval?, announce: Bool = true) {
        releaseAssertions()
        let types: [String] = Prefs.bool(.awakeDisplay)
            ? [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep]
            : [kIOPMAssertionTypePreventUserIdleSystemSleep]
        for t in types {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Peaky keeps your Mac awake" as CFString, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
        expiry?.invalidate()
        chosenSeconds = seconds
        until = seconds.map { Date().addingTimeInterval($0) }
        if let seconds {
            expiry = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.stop() }
        }
        ticker?.invalidate()
        if seconds != nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.objectWillChange.send() }
        }
        active = !assertions.isEmpty
        // Remember it, so a restart (or rebuild) doesn't silently let the Mac sleep.
        UserDefaults.standard.set(until?.timeIntervalSince1970 ?? -1, forKey: Self.savedUntilKey)
        UserDefaults.standard.set(seconds ?? -1, forKey: Self.savedChosenKey)
        if announce {
            IslandHub.post(.notice(Notice(key: "awake", symbol: "cup.and.saucer.fill", tint: .white, title: "Awake",
                                          detail: seconds.map { CalEvent.span($0) } ?? "Indefinitely",
                                          detailTint: .white.opacity(0.6), duration: 2.2)))
        }
    }

    func stop(announce: Bool = true) {
        let wasActive = active
        expiry?.invalidate()
        ticker?.invalidate()
        releaseAssertions()
        until = nil
        active = false
        UserDefaults.standard.removeObject(forKey: Self.savedUntilKey)
        UserDefaults.standard.removeObject(forKey: Self.savedChosenKey)
        if announce, wasActive {
            IslandHub.post(.notice(Notice(key: "awake", symbol: "moon.zzz.fill", tint: .white.opacity(0.7),
                                          title: "Sleep allowed", duration: 2)))
        }
    }

    func toggle() { active ? stop() : start(for: Self.defaultDuration) }

    private static let savedUntilKey = "awakeSavedUntil"
    private static let savedChosenKey = "awakeSavedChosen"

    /// At launch: pick up a keep-awake that was running when Peaky quit.
    func restore() {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.savedUntilKey) != nil else { return }
        let until = d.double(forKey: Self.savedUntilKey)
        let chosen = d.double(forKey: Self.savedChosenKey)
        if until < 0 {
            start(for: nil, announce: false)
        } else if until > Date().timeIntervalSince1970 + 5 {
            start(for: until - Date().timeIntervalSince1970, announce: false)
            chosenSeconds = chosen > 0 ? chosen : nil
        } else {
            d.removeObject(forKey: Self.savedUntilKey)
        }
    }

    static var defaultDuration: TimeInterval? {
        let v = UserDefaults.standard.double(forKey: Prefs.Key.awakeDefault.rawValue)
        return v > 0 ? v : nil
    }

    /// "42m", "1h 5m", "∞".
    var remainingShort: String {
        guard let until else { return "∞" }
        let m = max(0, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// Re-apply after the "keep the display awake" setting changes.
    func refreshKind() {
        guard active else { return }
        let keep = chosenSeconds
        start(for: until.map { max(1, $0.timeIntervalSinceNow) }, announce: false)
        chosenSeconds = keep
    }

    private func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }
}

/// The pixel coffee mug for the left slot: white mug, coffee top, handle, two wisps of steam.
struct PixelMug: View {
    static let px: CGFloat = 1.5
    static let grid = (w: 10, h: 8)
    static let size = CGSize(width: CGFloat(grid.w) * px, height: CGFloat(grid.h) * px)

    private static let image: NSImage = {
        let (w, h) = grid
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let mug = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).cgColor
        let shade = NSColor(srgbRed: 0.78, green: 0.76, blue: 0.73, alpha: 1).cgColor
        let coffee = NSColor(srgbRed: 0.45, green: 0.26, blue: 0.12, alpha: 1).cgColor
        let steam1 = NSColor.white.withAlphaComponent(0.55).cgColor
        let steam2 = NSColor.white.withAlphaComponent(0.3).cgColor
        var px: [(Int, Int, CGColor)] = []
        for x in 0...6 { px.append((x, 0, shade)) }
        for y in 1...2 { for x in 0...6 { px.append((x, y, mug)) } }
        px.append((0, 3, mug)); px.append((6, 3, mug))
        for x in 1...5 { px.append((x, 3, coffee)) }
        px += [(7, 1, mug), (8, 1, mug), (8, 2, mug), (7, 3, mug), (8, 3, mug)]
        px += [(2, 4, steam1), (2, 5, steam2), (4, 5, steam1), (4, 6, steam2)]
        for (x, y, c) in px { ctx.setFillColor(c); ctx.fill(CGRect(x: x, y: y, width: 1, height: 1)) }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: h))
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .interpolation(.none)
            .resizable()
            .frame(width: Self.size.width, height: Self.size.height)
            // The mug's body sits in the bottom half (steam above), so it read ~2.5 pt low next to the
            // music bars; lift it so the body is what's centred.
            .offset(y: -2.5)
    }
}

/// The mug shown at the right end of the island while the Mac is kept awake: the same white PixelMug as the left slot
/// One icon, white only.
struct CupBadge: View {
    var body: some View {
        // Fixed slot: the mug, then 11 pt of clear space before the island's rounded edge.
        PixelMug()
            .padding(.trailing, 11)
            .frame(width: IslandModel.cupWidth, alignment: .trailing)
    }
}

/// Open island: ☕ toggle with the time left; right-click for durations.
struct AwakeButton: View {
    @ObservedObject var awake = Services.shared.awake
    @State private var hover = false

    var body: some View {
        Button { awake.toggle() } label: {
            HStack(spacing: 4) {
                PixelMug().opacity(awake.active ? 1 : (hover ? 0.9 : 0.55))
                if awake.active { Text(awake.remainingShort).font(Theme.mono(10)) }
            }
            .foregroundStyle(awake.active ? Color.white : .white.opacity(hover ? 0.9 : 0.6))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(awake.active ? "Keeping your Mac awake — click to allow sleep" : "Keep your Mac awake")
        .contextMenu {
            ForEach(KeepAwake.choices, id: \.label) { c in
                Button(c.label) { awake.start(for: c.seconds) }
            }
            if awake.active {
                Divider()
                Button("Turn off") { awake.stop() }
            }
        }
    }
}
