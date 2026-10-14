import AppKit
import CoreImage
import SwiftUI

/// Mirrors the system Now Playing session (any app: Spotify, Music, Chrome, Safari…).
/// The data comes from Helper/PeakyMedia.m running inside /usr/bin/perl — see that file for why.
final class NowPlaying: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appBundleID: String?

    // Elapsed time is extrapolated from the last snapshot, so the UI never has to poll the helper.
    private var elapsedAtSnapshot: Double = 0
    private var snapshotDate = Date()
    private var rate: Double = 0

    /// After a play/pause tap, hold the tapped state until the player confirms it (or 1.5s pass),
    /// so an update that was already in flight can't flip the button back.
    private var expectedPlaying: Bool?
    private var expectedUntil = Date.distantPast

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false

    /// macOS keeps a paused app's session around forever (an old QuickTime video, a YouTube tab). After a
    /// minute with nothing playing Peaky forgets it: no player in the open island, no music activity.
    @Published private(set) var recentlyActive = false
    private var staleWork: DispatchWorkItem?
    static let staleAfter: TimeInterval = 60

    var hasMedia: Bool { !title.isEmpty && recentlyActive }
    /// Artist, else album; empty when the player gives neither (then the title sits centred).
    var subtitle: String { artist.isEmpty ? album : artist }

    private func updateRecency() {
        staleWork?.cancel()
        if isPlaying {
            if !recentlyActive { recentlyActive = true }
        } else if recentlyActive {
            let w = DispatchWorkItem { [weak self] in self?.recentlyActive = false }
            staleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleAfter, execute: w)
        }
    }

    func elapsed(at date: Date = Date()) -> Double {
        guard isPlaying else { return min(elapsedAtSnapshot, max(duration, elapsedAtSnapshot)) }
        let e = elapsedAtSnapshot + date.timeIntervalSince(snapshotDate) * (rate == 0 ? 1 : rate)
        return duration > 0 ? min(e, duration) : e
    }

    // MARK: - Commands

    func togglePlayPause() {
        send("toggle")
        // Optimistic flip so the button reacts instantly; the helper confirms a moment later.
        elapsedAtSnapshot = elapsed()
        snapshotDate = Date()
        isPlaying.toggle()
        updateRecency()
        expectedPlaying = isPlaying
        expectedUntil = Date().addingTimeInterval(1.5)
    }
    func next() { send("next") }
    func previous() { send("prev") }
    func seek(to seconds: Double) {
        send(String(format: "seek %.2f", seconds))
        elapsedAtSnapshot = seconds
        snapshotDate = Date()
    }

    func openSourceApp() {
        guard let id = appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: - Helper process

    func start() {
        guard let dylib = Bundle.main.url(forResource: "PeakyMedia", withExtension: "dylib") else {
            NSLog("Peaky: PeakyMedia.dylib missing from bundle — Now Playing disabled")
            return
        }
        let script = """
        use DynaLoader;
        my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die "load failed";
        my $s = DynaLoader::dl_find_symbol($l, "peaky_stream") or die "symbol missing";
        DynaLoader::dl_install_xsub("main::peaky_stream", $s);
        peaky_stream();
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", script, dylib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.stopping else { return }
                self.start()
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("Peaky: could not start media helper: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(obj)
            }
        }
    }

    private var artworkHash = 0

    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<NowPlaying, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private func apply(_ o: [String: Any]) {
        if let err = o["error"] as? String { NSLog("Peaky media helper: \(err)"); return }

        let pid = (o["pid"] as? NSNumber)?.intValue ?? 0
        let app = pid > 0 ? NSRunningApplication(processIdentifier: pid_t(pid)) : nil
        var playing = (o["playing"] as? NSNumber)?.boolValue ?? false
        if let expected = expectedPlaying {
            if playing == expected || Date() > expectedUntil { expectedPlaying = nil } else { playing = expected }
        }
        var newTitle = o["title"] as? String ?? ""
        // Some players (QuickTime, many web pages) publish a session with no title; show the app instead.
        if newTitle.isEmpty, let app, playing || (o["duration"] as? Double ?? 0) > 0 {
            newTitle = app.localizedName ?? ""
        }
        let trackChanged = newTitle != title

        // Players report several times a second while playing. Only touch what really changed: every
        // assignment to a @Published value redraws the island (the artwork and icon especially), which
        // kept Peaky at ~2 % CPU doing nothing visible.
        update(\.title, newTitle)
        update(\.artist, o["artist"] as? String ?? "")
        update(\.album, o["album"] as? String ?? "")
        update(\.duration, o["duration"] as? Double ?? 0)
        rate = o["rate"] as? Double ?? 0
        update(\.isPlaying, playing && !newTitle.isEmpty)
        updateRecency()

        let elapsed = o["elapsed"] as? Double ?? 0
        if let ts = o["timestamp"] as? Double {
            elapsedAtSnapshot = elapsed
            snapshotDate = Date(timeIntervalSince1970: ts)
        } else {
            elapsedAtSnapshot = elapsed
            snapshotDate = Date()
        }

        if let b64 = o["artwork"] as? String {
            // Same picture again (the usual case): don't decode it, don't redraw it.
            if b64.hashValue != artworkHash, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                artworkHash = b64.hashValue
                artwork = img
                accent = Color(nsColor: Self.accentColor(of: img))
            }
        } else if o["noArtwork"] != nil, trackChanged || newTitle.isEmpty, artwork != nil {
            artworkHash = 0
            artwork = nil
            accent = .white
        }

        if let app {
            if app.bundleIdentifier != appBundleID || appIcon == nil {
                appBundleID = app.bundleIdentifier
                appIcon = app.icon
            }
        } else if newTitle.isEmpty, appBundleID != nil || appIcon != nil {
            appBundleID = nil
            appIcon = nil
        }
    }

    /// Average colour of the artwork, lifted so it reads on a black island.
    static func accentColor(of image: NSImage) -> NSColor {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ]), let out = f.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(s * 1.2, 0.85), brightness: max(b, 0.75), alpha: 1)
    }
}
