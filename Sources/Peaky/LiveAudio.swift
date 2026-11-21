import Accelerate
import AppKit
import Combine
import CoreAudio

/// Something that shows the live levels: 4 values 0…1, bass first. `nil` means "no live sound to show"
/// (setting off, no permission, tap failed) — fall back to the decorative bars.
protocol LevelsSink: AnyObject {
    func show(_ levels: [Float]?)
}

/// Bars that follow the music, like the iPhone's Dynamic Island. Listens to the playing app's sound through a
/// CoreAudio process tap (macOS 14.2+), splits each moment into 4 bands — bass on the left, treble on the
/// right — and hands the levels to the bars. Nothing is recorded or kept: each buffer is measured and dropped.
/// It only runs while bars that want it are on screen and the setting is on.
final class LiveAudio {
    static let shared = LiveAudio()

    enum Access { case unknown, allowed, denied }

    private var sinks = NSHashTable<AnyObject>.weakObjects()
    private var tap: AnyObject?          // a Tap; typed loosely because Tap needs macOS 14.2
    private var tappedProcesses: [AudioObjectID] = []
    private var stopWork: DispatchWorkItem?
    private var ticker: DispatchSourceTimer?
    private var shown: [Float] = [0, 0, 0, 0]
    private var appWatch: AnyCancellable?
    private var listWatching = false

    /// Written on the audio queue, read on main.
    private let lock = NSLock()
    private var latest: [Float] = [0, 0, 0, 0]
    private var lastAudio = Date.distantPast
    /// When a band last had any sound, and when listening began.
    private var lastSound = Date.distantPast
    private var startedAt = Date()
    /// Nothing heard for a while although the player says it's playing (wrong process, or no permission):
    /// the bars bounce as before rather than lie flat.
    private var heardNothing = false

    var isRunning: Bool { tap != nil }

    // MARK: Bars come and go

    func attach(_ sink: LevelsSink) {
        stopWork?.cancel(); stopWork = nil
        sinks.add(sink)
        if tap == nil { start() }
        sink.show(tap == nil || heardNothing ? nil : shown)
    }

    func detach(_ sink: LevelsSink) {
        sinks.remove(sink)
        guard sinks.allObjects.isEmpty, tap != nil, stopWork == nil else { return }
        // Moving between the compact bars and the hover peek swaps one view for another; don't tear down for that.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sinks.allObjects.isEmpty else { return }
            self.stop()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func broadcast(_ levels: [Float]?) {
        for case let s as LevelsSink in sinks.allObjects { s.show(levels) }
    }

    // MARK: Start / stop

    private func start() {
        guard #available(macOS 14.2, *), Prefs.bool(.liveBars), Self.access != .denied else { return }
        if appWatch == nil {
            // A different player took over: listen to that one instead.
            appWatch = Services.shared.nowPlaying.$appBundleID.removeDuplicates().dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.playerChanged() }
            }
        }
        watchProcessList()
        let app = Services.shared.nowPlaying.appBundleID
        let processes = app.map { AudioActivity.shared.processObjects(of: $0) } ?? []
        if debugFake {
            tap = FakeSource { [weak self] levels in self?.received(levels) }
        } else if processes.isEmpty {
            // Only ever the player's own sound — never everything (that would include a call you're on).
            Self.log("no audio process found for \(app ?? "the player"); keeping the decorative bars")
            return
        } else { do {
            tap = try Tap(processes: processes) { [weak self] levels in self?.received(levels) }
            tappedProcesses = processes
            Self.log("listening to \(app ?? "everything") (\(processes.count) process\(processes.count == 1 ? "" : "es"))")
        } catch {
            Self.log("tap failed: \(error)")
            tap = nil
            return
        } }
        shown = [0, 0, 0, 0]
        startedAt = Date()
        heardNothing = false
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    private func stop() {
        ticker?.cancel(); ticker = nil
        tap = nil
        tappedProcesses = []
        broadcast(nil)
    }

    private func restartIfRunning() {
        guard tap != nil else { return }
        stop()
        start()
        broadcast(tap == nil ? nil : shown)
    }

    /// A different player took over, or the first one became known after the bars appeared.
    private func playerChanged() {
        if tap != nil { restartIfRunning() }
        else if !sinks.allObjects.isEmpty { start(); broadcast(tap == nil || heardNothing ? nil : shown) }
    }

    /// Chrome / Safari start a fresh audio process now and then; follow it.
    private func watchProcessList() {
        guard !listWatching else { return }
        listWatching = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self, !self.sinks.allObjects.isEmpty, let app = Services.shared.nowPlaying.appBundleID,
                  AudioActivity.shared.processObjects(of: app) != self.tappedProcesses else { return }
            self.playerChanged()
        }
    }

    /// The setting was switched, or the permission changed: wake or stop the bars that are already on screen.
    func settingChanged() {
        let wanted = Prefs.bool(.liveBars) && Self.access != .denied
        if wanted, !sinks.allObjects.isEmpty, tap == nil {
            start()
            broadcast(tap == nil ? nil : shown)
        } else if !wanted, tap != nil {
            stop()
        }
    }

    // MARK: Levels

    private func received(_ levels: [Float]) {
        lock.lock()
        latest = levels
        lastAudio = Date()
        if levels.contains(where: { $0 > 0 }) { lastSound = lastAudio }
        lock.unlock()
    }

    /// 30× a second on main: rise at once, fall back gently (what makes it read as a pulse, not a flicker).
    private func tick() {
        lock.lock()
        let target = Date().timeIntervalSince(lastAudio) < 0.25 ? latest : [0, 0, 0, 0]
        let quiet = Date().timeIntervalSince(max(lastSound, startedAt)) > 3
        lock.unlock()
        if quiet != heardNothing {
            heardNothing = quiet
            if quiet { Self.log("no sound for 3 s; decorative bars until there is") }
            broadcast(quiet ? nil : shown)
        }
        guard !quiet else { return }
        let before = shown
        for i in 0..<4 { shown[i] = target[i] > shown[i] ? target[i] : max(target[i], shown[i] * 0.82) }
        guard zip(before, shown).contains(where: { abs($0 - $1) > 0.005 }) else { return }   // silence: nothing to redraw
        // One commit for every display's bars, not one each.
        CATransaction.begin()
        broadcast(shown)
        CATransaction.commit()
    }

    // MARK: Permission ("Screen & System Audio Recording" → "System Audio Recording Only")

    /// macOS has no public call to ask; this is the same TCC call Apple's own apps use.
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var access: Access {
        guard let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .unknown
        }
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        guard let sym = dlsym(tcc, "TCCAccessRequest") else { done(true); return }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { ok in DispatchQueue.main.async { done(ok) } }
    }

    static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    static func log(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Peaky")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("liveaudio.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Debug only (`peakyctl fakelevels`): a made-up beat instead of the tap, to check the bars without sound.
    var debugFake = false
    private final class FakeSource {
        private let timer = DispatchSource.makeTimerSource(queue: .global())
        init(_ out: @escaping ([Float]) -> Void) {
            let start = Date()
            timer.schedule(deadline: .now(), repeating: 0.01)
            timer.setEventHandler {
                let t = Float(Date().timeIntervalSince(start))
                let kick = max(0, 1 - (t.truncatingRemainder(dividingBy: 0.5)) * 4)
                out([kick, 0.35 + 0.3 * sin(t * 5), 0.5 + 0.4 * sin(t * 9 + 1), 0.25 + 0.25 * sin(t * 17 + 2)])
            }
            timer.resume()
        }
        deinit { timer.cancel() }
    }

    var debugState: String {
        lock.lock(); defer { lock.unlock() }
        let age = Date().timeIntervalSince(lastAudio)
        return "playing=\(Services.shared.nowPlaying.isPlaying) live=\(tap != nil) access=\(Self.access) sinks=\(sinks.allObjects.count) processes=\(tappedProcesses) "
            + "audioAge=\(String(format: "%.2f", age)) latest=\(latest.map { String(format: "%.2f", $0) }) "
            + "shown=\(shown.map { String(format: "%.2f", $0) })"
    }
}

// MARK: - The tap

extension LiveAudio {
    struct TapError: Error, CustomStringConvertible {
        let step: String, status: OSStatus
        var description: String { "\(step) → \(status)" }
    }

    /// A private, unmuted stereo tap on some processes, read through a private aggregate device.
    /// Torn down when released.
    @available(macOS 14.2, *)
    final class Tap {
        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var deviceID = AudioObjectID(kAudioObjectUnknown)
        private var procID: AudioDeviceIOProcID?
        private let queue = DispatchQueue(label: "peaky.liveaudio", qos: .userInteractive)

        init(processes: [AudioObjectID], onLevels: @escaping ([Float]) -> Void) throws {
            let desc = CATapDescription(stereoMixdownOfProcesses: processes)
            desc.name = "Peaky bars"
            desc.isPrivate = true
            desc.muteBehavior = .unmuted
            try check("create tap", AudioHardwareCreateProcessTap(desc, &tapID))

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            try check("tap format", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format))
            guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw TapError(step: "tap format not float32", status: OSStatus(format.mFormatFlags))
            }

            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Peaky bars",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            try check("aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID))

            var meter = BandMeter(sampleRate: format.mSampleRate)
            try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                meter.feed(buffers)
                onLevels(meter.levels())
            })
            try check("start", AudioDeviceStart(deviceID, procID))
        }

        deinit {
            if deviceID != kAudioObjectUnknown {
                AudioDeviceStop(deviceID, procID)
                if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
            if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        }

        private func check(_ step: String, _ status: OSStatus) throws {
            guard status == noErr else { throw TapError(step: step, status: status) }
        }

        private static func defaultOutputUID() throws -> String {
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
            guard status == noErr else { throw TapError(step: "output device", status: status) }
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            addr.mSelector = kAudioDevicePropertyDeviceUID
            status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
            guard status == noErr, let s = uid?.takeRetainedValue() as String? else { throw TapError(step: "output uid", status: status) }
            return s
        }
    }
}

// MARK: - Sound → 4 bars

/// Splits sound into 4 bands (bass, low-mid, high-mid, treble) and turns each into a 0…1 bar height.
/// Each band is scaled against its own recent loudest moment, so quiet songs and loud songs both fill the bars
/// and a bass-heavy track doesn't flatten the treble bar.
struct BandMeter {
    static let log2n: vDSP_Length = 11
    static let size = 1 << Int(log2n)                  // 2048 samples ≈ 43 ms at 48 kHz: enough to tell bass apart
    static let bands: [(Double, Double)] = [(40, 160), (160, 700), (700, 3000), (3000, 12000)]
    static let range: Float = 30                       // dB between an empty bar and a full one
    static let silence: Float = -75                    // dB: below this a band reads as nothing
    static let boost: Float = 12                       // dB a quiet band may be lifted, at most, against the loudest

    private let sampleRate: Double
    private var ring = [Float](repeating: 0, count: size)
    private var peaks: [Float] = [-40, -40, -40, -40]
    private let window: [Float]
    private let fft: FFTSetup

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
    }

    /// Mixes whatever channels arrive down to mono and keeps the most recent `size` samples.
    mutating func feed(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        var count: Float = 0
        for b in buffers {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { continue }
            let ch = Int(b.mNumberChannels), n = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size / ch)
            for c in 0..<ch {
                for i in 0..<n { mono[i] += data[i * ch + c] }
                count += 1
            }
        }
        if count > 1 { vDSP.multiply(1 / count, mono, result: &mono) }
        feed(mono)
    }

    mutating func feed(_ samples: [Float]) {
        let n = Self.size
        if samples.count >= n {
            ring = Array(samples.suffix(n))
        } else {
            ring.removeFirst(samples.count)
            ring.append(contentsOf: samples)
        }
    }

    /// Band levels for the latest window, 0…1.
    mutating func levels() -> [Float] {
        let n = Self.size, half = n / 2
        var windowed = vDSP.multiply(ring, window)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0                             // packed Nyquist; not a real bin here
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        // zrip returns 2× the DFT, and a full-scale sine puts ~(n/4)² into its bin with this window: scale so
        // a full-scale tone reads ≈ 0 dB.
        let scale = 1 / Float(n * n / 4)
        let binHz = sampleRate / Double(n)
        let db: [Float] = Self.bands.map { lo, hi in
            let from = max(1, Int(lo / binHz)), to = min(half - 1, max(from, Int(hi / binHz)))
            var sum: Float = 0
            for k in from...to { sum += power[k] }
            return 10 * log10(max(sum * scale, 1e-12))
        }
        // Each ceiling follows its band's loudest recent moment, sinking ~6 dB a second (levels() runs ~100×/s),
        // but never more than `boost` below the loudest band's — so a band that's merely leakage stays low.
        let loudest = zip(db, peaks).map { max($0, $1 - 0.06) }.max() ?? Self.silence
        var out = [Float](repeating: 0, count: 4)
        for b in 0..<4 {
            peaks[b] = max(db[b], peaks[b] - 0.06, loudest - Self.boost, Self.silence + Self.range)
            out[b] = db[b] < Self.silence ? 0 : min(1, max(0, (db[b] - (peaks[b] - Self.range)) / Self.range))
        }
        return out
    }
}
