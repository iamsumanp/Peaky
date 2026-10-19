import CoreAudio
import Foundation

/// Which apps are sending sound to the speakers right now — straight from CoreAudio, event-driven (no polling).
/// Some players (Chrome on some sites) tell macOS "paused" while the video plays on; this is the ground truth.
final class AudioActivity {
    static let shared = AudioActivity()
    /// Called on the main queue whenever any app starts or stops producing sound.
    var onChange: () -> Void = {}

    private var watched = Set<AudioObjectID>()
    private let queue = DispatchQueue.main

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        var list = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, queue) { [weak self] _, _ in
            self?.watchProcesses()
            self?.onChange()
        }
        watchProcesses()
    }

    private func processObjects() -> [AudioObjectID] {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func watchProcesses() {
        for id in processObjects() where !watched.contains(id) {
            watched.insert(id)
            var running = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectAddPropertyListenerBlock(id, &running, queue) { [weak self] _, _ in self?.onChange() }
        }
    }

    /// Is this app (or one of its helper processes, e.g. Chrome's audio service, Safari's WebKit) playing sound?
    func isPlaying(appBundleID app: String) -> Bool {
        let webKit = app == "com.apple.Safari" || app.hasPrefix("com.apple.SafariTechnologyPreview")
        for id in processObjects() {
            var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr, running != 0 else { continue }
            var bid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            addr = Self.address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &bid) == noErr,
                  let b = bid?.takeRetainedValue() as String? else { continue }
            if b.hasPrefix(app) || (webKit && b.hasPrefix("com.apple.WebKit")) { return true }
        }
        return false
    }
}
