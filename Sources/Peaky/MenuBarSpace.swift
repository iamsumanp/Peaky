import AppKit

/// How much of the menu bar beside the notch is free on one screen. The island's compact ears stay inside it,
/// so they never cover the app's menus (left) or the menu bar icons (right). `.infinity` = not known.
struct MenuBarRoom: Equatable {
    var left: CGFloat = .infinity
    var right: CGFloat = .infinity
    static let unlimited = MenuBarRoom()
}

/// Where the menu bar is busy: the front app's menus (left of the notch) and the menu bar icons (right of it).
/// macOS only tells this through Accessibility, so it works once Peaky is allowed there; until then nothing is
/// known and the island behaves as before. Read off the main thread (a slow app can't stall the notch) and only
/// when something moves: apps launching, quitting or switching, plus a slow refresh for icons that change width.
final class MenuBarSpace {
    static let shared = MenuBarSpace()
    /// Called on main when the busy areas change.
    var onChange: () -> Void = {}

    /// Global x ranges (Cocoa coordinates) of the front app's menus.
    private(set) var menus: [ClosedRange<CGFloat>] = []
    /// For each notched screen, the global x where the first menu bar icon right of the notch begins.
    private(set) var iconStarts: [CGFloat] = []

    private let queue = DispatchQueue(label: "peaky.menubar", qos: .utility)
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            // An app's menus and icons appear a moment after it activates or launches.
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh(after: 0.6) })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 5
        refresh()
    }

    func refresh(after delay: TimeInterval = 0) {
        pending?.cancel()
        let screens = NSScreen.screens.compactMap(Self.notch)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let work = DispatchWorkItem { [weak self] in self?.read(screens, primaryHeight: primaryHeight) }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The free space beside this screen's notch.
    func room(on screen: NSScreen) -> MenuBarRoom {
        guard let n = Self.notch(screen) else { return .unlimited }
        var room = MenuBarRoom()
        // A little air so the island's rounded end doesn't touch the next item.
        let menuEnd = menus.filter { $0.upperBound <= n.left + 1 && $0.lowerBound >= n.frame.minX }.map(\.upperBound).max()
        if let menuEnd { room.left = max(0, n.left - menuEnd - 8) }
        if let start = iconStarts.filter({ $0 >= n.right - 1 && $0 <= n.frame.maxX }).min() { room.right = max(0, start - n.right - 6) }
        return room
    }

    private struct Notch { let frame: CGRect, left: CGFloat, right: CGFloat }

    private static func notch(_ screen: NSScreen) -> Notch? {
        guard let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return nil }
        return Notch(frame: screen.frame, left: screen.frame.minX + l.maxX, right: screen.frame.minX + r.minX)
    }

    // MARK: Reading the menu bar (background queue)

    private func read(_ screens: [Notch], primaryHeight: CGFloat) {
        guard AXIsProcessTrusted() else { publish([], []); return }
        var menus: [ClosedRange<CGFloat>] = []
        if let front = NSWorkspace.shared.frontmostApplication {
            menus = Self.menuItems(of: front.processIdentifier)
        }
        // Every app with menu bar icons has an extra "menu bar" of its own, just as wide as its icons (Reef
        // 997–1037, Stats 1081–1183…). Asking each app is reliable whichever app is in front.
        let tops = screens.map { primaryHeight - $0.frame.maxY }   // Accessibility: y runs down from the primary's top
        var bars: [CGRect] = []
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.15)   // a hung app answers nothing rather than stalling us
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
                  let f = Self.frame(of: bar as! AXUIElement) else { continue }
            guard f.width > 0, f.height < 60,
                  tops.contains(where: { f.minY >= $0 - 1 && f.minY < $0 + 20 }) else { continue }   // in a top strip
            bars.append(f)
        }
        let icons: [CGFloat] = screens.compactMap { n in
            bars.filter { $0.minX >= n.right - 1 && $0.maxX <= n.frame.maxX }.map(\.minX).min()
        }
        publish(menus, icons)
    }

    private func publish(_ menus: [ClosedRange<CGFloat>], _ icons: [CGFloat]) {
        DispatchQueue.main.async {
            guard menus != self.menus || icons != self.iconStarts else { return }
            self.menus = menus
            self.iconStarts = icons
            self.onChange()
        }
    }

    private static func menuItems(of pid: pid_t) -> [ClosedRange<CGFloat>] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)   // a hung app answers nothing rather than stalling us
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return [] }
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let children = kids as? [AXUIElement] else { return [] }
        return children.compactMap { item in
            guard let f = frame(of: item), f.width > 0, f.height > 0, f.height < 60 else { return nil }
            return f.minX...f.maxX
        }
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success, let p, let s else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    var debugState: String {
        let screens = NSScreen.screens.map { "\($0.localizedName): \(room(on: $0))" }.joined(separator: "; ")
        return "trusted=\(AXIsProcessTrusted()) menus=\(menus.map { "\(Int($0.lowerBound))-\(Int($0.upperBound))" }) "
            + "iconStarts=\(iconStarts.map { Int($0) }) rooms=\(screens)"
    }
}
