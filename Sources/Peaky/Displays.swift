import AppKit
import SwiftUI

/// Which monitors get an island. Monitors are remembered by their hardware UUID, so the choice survives
/// unplugging, sleeping and rearranging.
enum Displays {
    private static let key = "enabledDisplays"

    struct Info: Identifiable, Equatable {
        let id: String       // display UUID
        let name: String     // "BenQ GW2490"
        let detail: String   // "1920 × 1080 · external"
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func uuid(_ s: NSScreen) -> String {
        let did = displayID(s)
        guard let u = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue() else { return "id-\(did)" }
        return CFUUIDCreateString(nil, u) as String
    }

    static func info(_ s: NSScreen) -> Info {
        let did = displayID(s)
        var size = "\(Int(s.frame.width)) × \(Int(s.frame.height))"
        if let mode = CGDisplayCopyDisplayMode(did) { size = "\(mode.pixelWidth) × \(mode.pixelHeight)" }
        var tags = [size]
        if CGDisplayIsBuiltin(did) != 0 { tags.append("built-in") } else { tags.append("external") }
        if s.safeAreaInsets.top > 0 { tags.append("notch") }
        return Info(id: uuid(s), name: s.localizedName, detail: tags.joined(separator: " · "))
    }

    /// Explicit choice, or nil until the user has picked anything.
    private static var chosen: Set<String>? {
        (UserDefaults.standard.array(forKey: key) as? [String]).map(Set.init)
    }

    /// Before any choice: the notch screen (or the main screen if there is none), as before.
    private static func defaultOn(_ s: NSScreen) -> Bool {
        let notched = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        return notched.isEmpty ? s == NSScreen.main : s.safeAreaInsets.top > 0
    }

    static func isEnabled(_ s: NSScreen) -> Bool {
        chosen.map { $0.contains(uuid(s)) } ?? defaultOn(s)
    }

    static func setEnabled(_ s: NSScreen, _ on: Bool) {
        // First change: start from what is currently shown, so nothing else flips.
        var set = chosen ?? Set(NSScreen.screens.filter(defaultOn).map(uuid))
        if on { set.insert(uuid(s)) } else { set.remove(uuid(s)) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: key)
    }

    static var selectedScreens: [NSScreen] { NSScreen.screens.filter(isEnabled) }

    // MARK: Full-screen apps

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceTypeFn = @convention(c) (Int32, UInt64) -> Int32
    private static let sky: (cid: Int32, current: CurrentSpaceFn, type: SpaceTypeFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c = dlsym(h, "SLSMainConnectionID"), let cur = dlsym(h, "SLSManagedDisplayGetCurrentSpace"),
              let t = dlsym(h, "SLSSpaceGetType") else { return nil }
        return (unsafeBitCast(c, to: ConnFn.self)(), unsafeBitCast(cur, to: CurrentSpaceFn.self),
                unsafeBitCast(t, to: SpaceTypeFn.self))
    }()

    // Per monitor: keep the island over full-screen apps? Default: yes on the MacBook, no on externals.
    private static let fullscreenKey = "fullscreenDisplays"

    static func showsOverFullscreen(_ s: NSScreen) -> Bool {
        if let set = UserDefaults.standard.array(forKey: fullscreenKey) as? [String] { return set.contains(uuid(s)) }
        return CGDisplayIsBuiltin(displayID(s)) != 0
    }

    static func setShowsOverFullscreen(_ s: NSScreen, _ on: Bool) {
        var set = Set((UserDefaults.standard.array(forKey: fullscreenKey) as? [String])
            ?? NSScreen.screens.filter { CGDisplayIsBuiltin(displayID($0)) != 0 }.map(uuid))
        if on { set.insert(uuid(s)) } else { set.remove(uuid(s)) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: fullscreenKey)
    }

    /// Is this monitor currently showing a full-screen app's space? (Space type 4; desktops are 0.)
    static func isShowingFullscreenApp(_ s: NSScreen) -> Bool {
        guard let sky else { return false }
        let space = sky.current(sky.cid, uuid(s) as CFString)
        return space != 0 && sky.type(sky.cid, space) == 4
    }

    /// Part of the "did anything change?" signature for rebuilding islands.
    static var selectionSignature: String { selectedScreens.map(uuid).joined(separator: ",") }
}

/// Live list of connected monitors for Settings.
final class DisplayList: ObservableObject {
    @Published private(set) var screens: [(screen: NSScreen, info: Displays.Info)] = []
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        // Built-in first, then the rest left to right.
        screens = NSScreen.screens
            .sorted { a, b in
                let ab = CGDisplayIsBuiltin(Displays.displayID(a)) != 0, bb = CGDisplayIsBuiltin(Displays.displayID(b)) != 0
                return ab != bb ? ab : a.frame.minX < b.frame.minX
            }
            .map { ($0, Displays.info($0)) }
    }

    func fullscreenBinding(_ s: NSScreen) -> Binding<Bool> {
        Binding(
            get: { Displays.showsOverFullscreen(s) },
            set: { on in
                Displays.setShowsOverFullscreen(s, on)
                self.objectWillChange.send()
                AppDelegate.shared.rebuildIslands()
            })
    }

    func binding(_ s: NSScreen) -> Binding<Bool> {
        Binding(
            get: { Displays.isEnabled(s) },
            set: { on in
                Displays.setEnabled(s, on)
                self.objectWillChange.send()
                AppDelegate.shared.rebuildIslands()
            })
    }
}
