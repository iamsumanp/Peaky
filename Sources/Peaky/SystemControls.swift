import AppKit
import AudioToolbox
import CoreAudio

// MARK: - Volume

/// Watches (and sets) the default output device's volume via CoreAudio. No permissions needed.
final class VolumeService {
    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioObjectID(0)
    private var lastVolume: Float = -1
    private var lastMuted = false
    /// Output switches (AirPods connecting) report a burst of volume changes; ignore them for a moment.
    private var quietUntil = Date.distantPast
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.bindDefaultDevice()
        }
        bindDefaultDevice()
    }

    private func bindDefaultDevice() {
        for (var addr, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
        }
        listeners.removeAll()

        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        device = id

        // Different devices expose volume on the main element or per channel, so watch all of them.
        let watched: [(AudioObjectPropertySelector, UInt32)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
        ]
        for (sel, el) in watched {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: el)
            guard AudioObjectHasProperty(device, &a) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(device, &a, .main, block) == noErr {
                listeners.append((a, block))
            }
        }
        // Re-baseline silently so switching to AirPods doesn't flash a HUD.
        lastVolume = volume
        lastMuted = muted
        quietUntil = Date().addingTimeInterval(2.5)
    }

    private func changed() {
        let v = volume, m = muted
        guard abs(v - lastVolume) > 0.001 || m != lastMuted else { return }
        lastVolume = v
        lastMuted = m
        guard Date() > quietUntil else { return }
        onChange?(v, m)
    }

    private var mainVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    var volume: Float {
        get {
            var addr = mainVolumeAddress
            var v = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr else { return 0 }
            return v
        }
        set {
            var addr = mainVolumeAddress
            var v = Float32(max(0, min(1, newValue)))
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    var muted: Bool {
        get {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var m = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectHasProperty(device, &addr),
                  AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &m) == noErr else { return false }
            return m != 0
        }
        set {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var m = UInt32(newValue ? 1 : 0)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

// MARK: - Brightness

/// Built-in display brightness through the private DisplayServices framework.
final class BrightnessService {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private var getFn: GetFn?
    private var setFn: SetFn?

    init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else { return }
        if let g = dlsym(h, "DisplayServicesGetBrightness") { getFn = unsafeBitCast(g, to: GetFn.self) }
        if let s = dlsym(h, "DisplayServicesSetBrightness") { setFn = unsafeBitCast(s, to: SetFn.self) }
    }

    private var builtinDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    var brightness: Float {
        get {
            guard let getFn, let d = builtinDisplay else { return 0 }
            var b: Float = 0
            return getFn(d, &b) == 0 ? b : 0
        }
        set {
            guard let setFn, let d = builtinDisplay else { return }
            _ = setFn(d, max(0, min(1, newValue)))
        }
    }
}

// MARK: - Media keys

/// Intercepts the volume and brightness keys so the system HUD never appears and Peaky's does instead.
/// Needs Accessibility permission (an event tap).
final class MediaKeyTap {
    private(set) var running = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?

    var volume: VolumeService!
    var brightness: BrightnessService!

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        guard !running else { return }
        guard Self.trusted else {
            // Keep checking quietly until the user flips the switch in System Settings.
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if Self.trusted { t.invalidate(); self?.start() }
            }
            return
        }
        retryTimer?.invalidate()
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return me.handle(event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Peaky: could not create event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        running = true
    }

    func stop() {
        retryTimer?.invalidate()
        guard running else { return }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        running = false
    }

    /// Returns true when the event was consumed.
    private func handle(_ cg: CGEvent) -> Bool {
        guard let e = NSEvent(cgEvent: cg), e.type == .systemDefined, e.subtype.rawValue == 8 else { return false }
        let key = (e.data1 & 0xFFFF0000) >> 16
        let flags = e.data1 & 0xFFFF
        let down = ((flags & 0xFF00) >> 8) == 0xA
        let fine = e.modifierFlags.contains(.shift) && e.modifierFlags.contains(.option)
        let step: Float = fine ? 1 / 64 : 1 / 16

        switch key {
        case 0, 1: // NX_KEYTYPE_SOUND_UP / DOWN
            if down {
                var v = volume.volume
                if key == 0 {
                    if volume.muted { volume.muted = false }
                    v = min(1, (v / step).rounded() * step + step)
                } else {
                    v = max(0, (v / step).rounded() * step - step)
                }
                volume.volume = v
                IslandHub.post(.hud(HUDState(kind: .volume, value: v, muted: volume.muted)))
            }
            return true
        case 7: // NX_KEYTYPE_MUTE
            if down {
                volume.muted.toggle()
                IslandHub.post(.hud(HUDState(kind: .volume, value: volume.volume, muted: volume.muted)))
            }
            return true
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
            if down {
                var b = brightness.brightness
                b = key == 2 ? min(1, (b / step).rounded() * step + step) : max(0, (b / step).rounded() * step - step)
                brightness.brightness = b
                IslandHub.post(.hud(HUDState(kind: .brightness, value: b, muted: false)))
            }
            return true
        default:
            return false
        }
    }
}
