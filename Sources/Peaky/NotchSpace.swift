import AppKit

/// A private window-server space that sits above every desktop and full-screen app.
///
/// Windows on normal spaces (even `.canJoinAllSpaces`) are carried along by the desktop-switch
/// animation, so the island blinked out and back whenever you swiped between desktops or into a
/// full-screen app. A window living in its own top-level space never takes part in that animation.
/// (SkyLight is private API; if it ever goes away we silently fall back to the normal behaviour.)
final class NotchSpace {
    static let shared = NotchSpace()

    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesOp = @convention(c) (Int32, CFArray) -> Int32
    private typealias WindowsSpacesOp = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private var cid: Int32 = 0
    private var space: UInt64 = 0
    private var addWindows: WindowsSpacesOp?
    private var removeWindows: WindowsSpacesOp?

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let conn = dlsym(h, "SLSMainConnectionID") ?? dlsym(h, "_CGSDefaultConnection"),
              let create = dlsym(h, "SLSSpaceCreate"),
              let level = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let show = dlsym(h, "SLSShowSpaces"),
              let add = dlsym(h, "SLSAddWindowsToSpaces"),
              let remove = dlsym(h, "SLSRemoveWindowsFromSpaces") else {
            NSLog("Peaky: SkyLight space API unavailable; island will follow desktop switches")
            return
        }
        cid = unsafeBitCast(conn, to: DefaultConnection.self)()
        // Flag must be 1, otherwise Finder starts drawing desktop icons into the space.
        space = unsafeBitCast(create, to: SpaceCreate.self)(cid, 1, nil)
        guard space != 0 else { return }
        _ = unsafeBitCast(level, to: SpaceSetLevel.self)(cid, space, Int32.max)
        _ = unsafeBitCast(show, to: SpacesOp.self)(cid, [NSNumber(value: space)] as CFArray)
        addWindows = unsafeBitCast(add, to: WindowsSpacesOp.self)
        removeWindows = unsafeBitCast(remove, to: WindowsSpacesOp.self)
    }

    func add(_ window: NSWindow) {
        if UserDefaults.standard.bool(forKey: "debugNoSpace") { return }
        guard space != 0, let addWindows, window.windowNumber > 0 else { return }
        _ = addWindows(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    func remove(_ window: NSWindow) {
        guard space != 0, let removeWindows, window.windowNumber > 0 else { return }
        _ = removeWindows(cid, [NSNumber(value: window.windowNumber)] as CFArray, [NSNumber(value: space)] as CFArray)
    }

    // MARK: Keeping a window off full-screen spaces

    private typealias CopyManagedSpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private lazy var copyManagedSpaces: CopyManagedSpaces? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let f = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(f, to: CopyManagedSpaces.self)
    }()

    /// IDs of the full-screen-app spaces (type 4) on the display with this UUID.
    func fullscreenSpaces(onDisplay uuid: String) -> [UInt64] {
        guard let copy = copyManagedSpaces, let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let match = displays.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame }
            // With "Displays have separate Spaces" off, everything is listed under one "Main" entry.
            ?? (displays.count == 1 ? displays.first : nil)
        let spaces = match?["Spaces"] as? [[String: Any]] ?? []
        return spaces.compactMap { sp in
            guard (sp["type"] as? Int) == 4 else { return nil }
            return (sp["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (sp["id64"] as? NSNumber)?.uint64Value
        }
    }

    /// macOS joins all-desktops windows to full-screen spaces too; take this one back out of them.
    func keepOffFullscreenSpaces(_ window: NSWindow, displayUUID: String) {
        guard let removeWindows, window.windowNumber > 0 else { return }
        let ids = fullscreenSpaces(onDisplay: displayUUID)
        guard !ids.isEmpty else { return }
        _ = removeWindows(cid, [NSNumber(value: window.windowNumber)] as CFArray, ids.map { NSNumber(value: $0) } as CFArray)
    }
}
