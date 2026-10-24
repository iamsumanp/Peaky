import AppKit
import Combine
import SwiftUI

/// Borderless, transparent panel that sits above the menu bar, covering the notch.
final class NotchPanel: NSPanel {
    /// `overFullscreen`: stay visible over full-screen apps (lives in Peaky's own top-level space). Otherwise
    /// it's an ordinary all-desktops window that macOS itself keeps off full-screen spaces — removed in sync
    /// with the switch animation, with no lag.
    init(frame: NSRect, overFullscreen: Bool) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        collectionBehavior = overFullscreen ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                                            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        applyCapturePrivacy()
    }

    /// Screen sharing and recording see the screen without this window (setting: Hide Peaky from screen sharing).
    func applyCapturePrivacy() {
        sharingType = Prefs.bool(.hideFromCapture) ? .none : .readOnly
    }

    static func applyCapturePrivacy() {
        NSApp.windows.compactMap { $0 as? NotchPanel }.forEach { $0.applyCapturePrivacy() }
    }

    /// Normally never key (it must not take your typing). Clicking in the shelf lets it take the keyboard
    /// for ⌘A / Delete / Esc; closing the island hands it straight back.
    private var keyboardAllowed = false
    override var canBecomeKey: Bool { keyboardAllowed }

    func takeKeyboard() {
        keyboardAllowed = true
        if !isKeyWindow { makeKey() }
    }

    func giveBackKeyboard() {
        guard keyboardAllowed else { return }
        keyboardAllowed = false
        guard isKeyWindow else { return }
        // A key window gives up the keyboard when it leaves the screen; macOS hands it back to the window of
        // the app you were in (still the active app — Peaky never activates). Out and straight back in, in
        // the same frame, so the island doesn't blink.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            orderOut(nil)
            orderFrontRegardless()
        }
    }

    static func giveBackAll() {
        NSApp.windows.compactMap { $0 as? NotchPanel }.forEach { $0.giveBackKeyboard() }
    }
    override var canBecomeMain: Bool { false }
    // Don't let AppKit push us below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One island per screen. Owns the panel and decides when it should take the mouse:
/// the panel is click-through everywhere except over the island itself, so the menu bar keeps working.
final class NotchController {
    static let canvas = CGSize(width: 800, height: 320)

    let screen: NSScreen
    let model: IslandModel
    private(set) var panel: NotchPanel
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()

    private var leaveWork: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var hoverOpenWork: DispatchWorkItem?
    /// Drag-pasteboard change count while no mouse button is held; a different count during a press
    /// means a new drag started somewhere (Finder, Desktop…).
    private var idleDragCount = NSPasteboard(name: .drag).changeCount
    private var fileDragActive = false
    private var watcher: DispatchSourceTimer?
    /// Debug only: pretend the cursor is here (lets the hover path be tested without the real mouse).
    var fakeMouse: CGPoint?
    private var mouse: CGPoint { fakeMouse ?? NSEvent.mouseLocation }
    func wake() { updateMouse() }

    func debugGrab(_ on: Bool) { panel.ignoresMouseEvents = !on }
    func debugForceRedraw() { forceRedraw() }

    var debugState: String {
        "size=\(Int(model.size(for: model.presentation).width))x\(Int(model.size(for: model.presentation).height)) xoff=\(model.xOffset(for: model.presentation)) " +
        "closedHosts=\(model.closedHosts.sorted()) work=\(model.claudeWorking.count) showWorking=\(Prefs.bool(.claudeShowWorking)) " +
        "pres=\(model.presentation) expanded=\(model.expanded) hovering=\(model.hovering) ignoresMouse=\(panel.ignoresMouseEvents) " +
        "tracking=\(pollTimer != nil) | swiftui body=\(RenderProbe.bodyPresentation) \(String(format: "%.2fs ago", -RenderProbe.bodyAt.timeIntervalSinceNow)) " +
        "laidOutWidth=\(Int(RenderProbe.width)) \(String(format: "%.2fs ago", -RenderProbe.at.timeIntervalSinceNow)) | hostingLayer=\(Int(panel.contentView?.layer?.sublayers?.first?.bounds.width ?? -1))"
    }

    /// After something kept the island open (Quick Look): close it if the mouse is no longer over it.
    func collapseIfMouseLeft() {
        updateMouse()
        if model.expanded, !shelfSticky, !hitRect.contains(mouse) { model.collapse() }
    }

    /// The shelf (with files on it) is a workspace — select, drag into other apps, come back — so it doesn't
    /// close when the mouse wanders off, only on a click outside, Esc, or a swipe up.
    private var shelfSticky: Bool {
        model.expanded && model.tab == .shelf && (model.shelfCount > 0 || model.holdingShelf || fileDragActive)
    }

    /// Debug only: the notch centre in screen coordinates.
    var notchCentre: CGPoint { CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 10) }

    // swipe tracking
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0
    /// The current scroll gesture began over scrollable content, so it isn't an island swipe.
    private var scrollInContent = false

    private func overScrollableContent(_ e: NSEvent) -> Bool {
        guard model.expanded, let root = panel.contentView,
              let hit = root.hitTest(root.convert(e.locationInWindow, from: nil)) else { return false }
        var v: NSView? = hit
        while let view = v {
            if let sv = view as? NSScrollView, let doc = sv.documentView,
               doc.frame.height > sv.contentSize.height + 1 { return true }
            v = view.superview
        }
        return false
    }

    private var swipeFired = false
    private var lastWheel = Date.distantPast

    init(screen: NSScreen) {
        self.screen = screen
        model = IslandModel(geo: NotchGeometry(screen: screen))
        let f = screen.frame
        let rect = NSRect(x: f.midX - Self.canvas.width / 2, y: f.maxY - Self.canvas.height,
                          width: Self.canvas.width, height: Self.canvas.height)
        overFullscreen = Displays.showsOverFullscreen(screen)
        panel = NotchPanel(frame: rect, overFullscreen: overFullscreen)

        let host = FirstMouseHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        if overFullscreen { NotchSpace.shared.add(panel) } else { startKeepingOffFullscreen() }

        installMonitors()
        startWatcher()
        WakePort.shared.handler = { AppDelegate.shared.controllers.forEach { $0.wake() } }
        // When the island grows or shrinks under a stationary cursor, re-check hover.
        model.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updateMouse() }
            .store(in: &bag)
        // Opened without the cursor on it (menu, swipe overshoot): close again unless the user comes over.
        model.$expanded
            .filter { $0 }
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    guard let self, self.model.expanded, !self.model.hovering, !self.shelfSticky else { return }
                    self.model.collapse()
                }
            }
            .store(in: &bag)
    }

    /// Hidden while the Mac is locked: the island's space floats above the lock screen too,
    /// and meeting titles / alerts shouldn't show there.
    func setLocked(_ locked: Bool) {
        self.locked = locked
        applyVisibility()
    }

    let overFullscreen: Bool
    private var fullscreenGuard: DispatchSourceTimer?
    private var spaceObserver: NSObjectProtocol?

    /// For monitors that hide over full-screen apps: remove the island from their full-screen spaces now and
    /// whenever the space changes (that also catches a brand-new full-screen space the first time).
    private func startKeepingOffFullscreen() {
        let uuid = Displays.uuid(screen)
        let apply = { [weak self] in
            guard let self else { return }
            NotchSpace.shared.keepOffFullscreenSpaces(self.panel, displayUUID: uuid)
        }
        apply()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in apply() }
    }

    private var locked = false

    private func applyVisibility() {
        if locked {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
            if overFullscreen { NotchSpace.shared.add(panel) }
        }
    }

    func tearDown() {
        pollTimer?.cancel()
        watcher?.cancel()
        fullscreenGuard?.cancel()
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        NotchSpace.shared.remove(panel)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Hit testing

    private func islandRect(_ p: Presentation) -> CGRect {
        let s = model.size(for: p)
        let f = screen.frame
        return CGRect(x: f.midX - s.width / 2 + model.xOffset(for: p), y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private var hitRect: CGRect {
        let p = model.presentation
        var r: CGRect
        switch p {
        case .idle:
            let n = model.geo.notch
            let f = screen.frame
            r = CGRect(x: f.midX - n.width / 2, y: f.maxY - n.height, width: n.width, height: n.height)
                .insetBy(dx: -6, dy: 0)
        case .expanded, .peek:
            // Just the visible panel plus a hairline of slack, so it closes the moment you leave.
            r = islandRect(p).insetBy(dx: -8, dy: -8)
        default:
            r = islandRect(p).insetBy(dx: -4, dy: -4)
        }
        // The cursor can sit on the very top pixel row. With a display arranged above, it can also overshoot
        // onto that display; a strip of it directly above the island still counts as "on the island".
        r.size.height += displayAbove ? 36 : 4
        return r
    }

    private lazy var displayAbove: Bool = {
        let f = screen.frame
        return NSScreen.screens.contains { s in
            s !== screen && abs(s.frame.minY - f.maxY) < 2 && s.frame.minX < f.midX + 200 && s.frame.maxX > f.midX - 200
        }
    }()

    /// Where a file drag opens the shelf: well below the island too, so it opens before you reach the very top
    /// of the screen (pausing there with a drag opens Mission Control).
    private var dropZone: CGRect {
        let r = islandRect(.expanded)
        return CGRect(x: r.minX - 30, y: r.minY - 90, width: r.width + 60, height: r.height + 120)
    }

    // MARK: Mouse

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.mouseEvent(e) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.mouseEvent(e); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined, handler: { [weak self] e in
            guard e.subtype.rawValue == wakeSubtype else { return e }
            WakePort.shared.fire()
            // Must NOT return nil: AppKit runs its display pass after dispatching an event, and a swallowed
            // event skipped it — the island opened in the model but was only drawn once you moved away.
            return e
        }) {
            monitors.append(m)
        }
        // Clicks in other apps: the sticky shelf closes on a click anywhere outside it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.shelfSticky, !self.hitRect.contains(self.mouse) else { return }
            dragLog("shelf closed: click outside")
            self.model.collapse()
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            // A consumed event skips AppKit's display pass; wake it so a swipe's change is drawn now.
            if self.scroll(e) { postWake(); return nil }
            return e
        }) {
            monitors.append(m)
        }
    }

    private func mouseEvent(_ e: NSEvent) {
        updateMouse()
        if nearIsland(mouse) { startTracking() }
    }

    /// Mouse events don't reliably reach Peaky (e.g. while Finder runs a file drag), so a cheap 4 Hz
    /// check notices the cursor approaching the island and switches on precise tracking.
    private func startWatcher() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.idleDragCount = NSPasteboard(name: .drag).changeCount
            }
            if self.nearIsland(mouse) { self.startTracking() }
        }
        t.resume()
        watcher = t
    }

    /// Is a file being dragged right now? Checked from the tracking timer, not from events.
    private func updateFileDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            fileDragActive = false
            return
        }
        guard !fileDragActive else { return }
        let drag = NSPasteboard(name: .drag)
        if drag.changeCount != idleDragCount, drag.types?.contains(.fileURL) == true {
            fileDragActive = true
        }
    }

    /// Draw pending SwiftUI changes now, even outside AppKit's event-driven update cycle.
    private func forceRedraw() {
        guard let v = panel.contentView else { return }
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        CATransaction.flush()
    }

    /// A file drag hovering near the closed island should open the shelf.
    private var wantsShelf: Bool {
        fileDragActive && !model.expanded && dropZone.contains(mouse)
    }

    /// Once the island opens under the cursor, mouse events go to the island's own (non-key) window and
    /// often never reach the monitors — the hover state then went stale and the island closed under the
    /// cursor. So events only *wake* tracking; near the island the real cursor position is read every frame.
    ///
    /// This is a main-queue dispatch timer on purpose: SwiftUI changes made from a run-loop `Timer`
    /// callback in this accessory app were never drawn until some unrelated event arrived — the island
    /// "opened" in the model but only appeared once the cursor left.
    func startTracking() {
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let wasDragging = self.fileDragActive
            self.updateFileDrag()
            if self.fileDragActive != wasDragging {
                dragLog("file drag \(self.fileDragActive ? "started" : "ended")")
                self.model.fileDragging = self.fileDragActive
                self.forceRedraw()
                postWake()
            }
            let inside = self.cursorInside
            if self.panel.ignoresMouseEvents == inside { self.panel.ignoresMouseEvents = !inside }
            if self.wantsShelf {
                // Mid-drag, macOS may hold our posted wake-up events until the drag ends (the shelf then
                // opened only as you left). Open directly and push the change to the screen right away.
                dragLog("open shelf (cursor \(mouse))")
                self.model.expand(tab: .shelf)
                self.forceRedraw()
                postWake()
            }
            // Never change SwiftUI state from here: those changes weren't drawn until the next real event
            // (the island only appeared once the cursor left). Hand over to the event path instead.
            if inside != self.model.hovering { postWake() }
            if !self.model.hovering, !self.nearIsland(mouse) {
                self.pollTimer?.cancel()
                self.pollTimer = nil
            }
        }
        t.resume()
        pollTimer = t
    }


    private func nearIsland(_ p: CGPoint) -> Bool {
        islandRect(.expanded).insetBy(dx: -120, dy: -120).contains(p)
    }

    private var cursorInside: Bool {
        if locked { return false }
        let p = mouse
        return hitRect.contains(p) || (fileDragActive && model.expanded && dropZone.contains(p))
    }

    fileprivate func updateMouse() {
        let p = mouse
        if wantsShelf { model.expand(tab: .shelf) }
        let inside = cursorInside
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != model.hovering else { return }

        withAnimation(IslandModel.spring) { model.hovering = inside }
        if inside {
            leaveWork?.cancel()
            // A notice under the cursor stays put so it can be clicked (Join, back to Claude…).
            // Music peeks on hover (click to open fully); notices stay put so they can be clicked.
            if Prefs.bool(.openOnHover), !model.expanded, model.presentation != .notice, model.presentation != .peek {
                model.expand()
            }
        } else {
            hoverOpenWork?.cancel()
            if model.expanded {
                let w = DispatchWorkItem { [weak self] in
                    // Re-check the real cursor: only close if it is still outside. The shelf waits for a click.
                    guard let self, !self.shelfSticky, !self.model.hovering, !self.hitRect.contains(mouse) else { return }
                    self.model.collapse()
                }
                leaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
            }
        }
    }

    // MARK: Swipes

    /// Two-finger swipes on the island. Returns true when consumed.
    private func scroll(_ e: NSEvent) -> Bool {
        // A scroll that starts over something scrollable (the shelf's file grid) belongs to it, momentum and
        // all — otherwise "swipe up" closed the island the moment you tried to scroll the files.
        if e.phase == .began || e.phase == .mayBegin || (e.phase.isEmpty && e.momentumPhase.isEmpty) {
            scrollInContent = overScrollableContent(e)
        }
        if scrollInContent { return false }

        if !e.momentumPhase.isEmpty { return true }

        // Plain mouse wheel: no phases, treat each notch of the wheel on its own.
        if e.phase.isEmpty {
            guard Date().timeIntervalSince(lastWheel) > 0.4, abs(e.scrollingDeltaY) > 0.5 else { return true }
            lastWheel = Date()
            if e.scrollingDeltaY < 0 { model.expand() } else { model.collapse() }
            return true
        }

        if e.phase == .began || e.phase == .mayBegin {
            scrollX = 0; scrollY = 0; swipeFired = false
        }
        scrollX += e.scrollingDeltaX
        scrollY += e.scrollingDeltaY
        guard !swipeFired else { return true }

        // Natural scrolling flips the sign of the deltas; normalise to finger direction.
        let inv: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let fx = scrollX * inv, fy = scrollY * inv
        let np = Services.shared.nowPlaying

        if abs(fx) > 50, abs(fx) > abs(fy) * 1.4 {
            swipeFired = true
            if model.expanded {
                model.switchTab(forward: fx < 0)
            } else if np.hasMedia {
                fx < 0 ? np.next() : np.previous()
            }
        } else if abs(fy) > 30, abs(fy) > abs(fx) * 1.4 {
            swipeFired = true
            if fy > 0 { model.expand() } else { model.collapse() }
        }
        return true
    }
}

private let wakeSubtype: Int16 = 0x4E4B // "NK"

/// Changes made from Peaky's own timers / self-posted events were not drawn until some outside event
/// arrived, while changes made when a Mach-port message is handled (like a system notification) are.
/// So the tracking timer wakes the controllers through a Mach port on the main run loop.
final class WakePort: NSObject, NSMachPortDelegate {
    static let shared = WakePort()
    var handler: (() -> Void)?
    private let port = NSMachPort()
    private var pending = false

    override init() {
        super.init()
        port.setDelegate(self)
        RunLoop.main.add(port, forMode: .common)
    }

    func signal() {
        guard !pending else { return }
        pending = true
        let mode = UserDefaults.standard.string(forKey: "wakeMode") ?? "mach"
        switch mode {
        case "darwin":
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName("io.github.iamsumanp.peaky.wake" as CFString), nil, nil, true)
        case "event":
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: wakeSubtype, data1: 0, data2: 0) {
                NSApp.postEvent(e, atStart: false)
            }
        case "mouse":
            // a mouse-moved NSEvent posted into our own queue
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                NSApp.postEvent(e, atStart: false)
            }
            DispatchQueue.main.async { self.fire() }
        case "pid":
            // a CGEvent delivered to our own process by the window server
            if let e = CGEvent(source: nil) { e.type = .null; e.postToPid(getpid()) }
            DispatchQueue.main.async { self.fire() }
        default:
            port.send(before: Date(), components: nil, from: nil, reserved: 0)
        }
    }

    func fire() {
        pending = false
        handler?()
    }

    func handleMachMessage(_ msg: UnsafeMutableRawPointer) { fire() }
}

func postWake() { WakePort.shared.signal() }

/// Temporary: drag diagnostics in ~/Library/Logs/Peaky/drag.log
func dragLog(_ m: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peaky")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("drag.log")
    let line = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(m)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

/// Milliseconds since the last real keyboard/mouse input.
func hidIdleMs() -> Int {
    Int(CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) * 1000)
}
