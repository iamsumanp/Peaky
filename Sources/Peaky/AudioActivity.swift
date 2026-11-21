import AppKit
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
        processObjects(of: app).contains { id in
            var running: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr && running != 0
        }
    }

    /// The CoreAudio process objects that belong to this app: the app itself and its helpers.
    /// Matched by bundle ID prefix, or as a child process of the app: browsers play from helpers whose IDs don't
    /// always share the app's (Dia's sound comes from "company.thebrowser.browser.helper").
    func processObjects(of app: String) -> [AudioObjectID] {
        let webKit = app == "com.apple.Safari" || app.hasPrefix("com.apple.SafariTechnologyPreview")
        let appPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: app).map(\.processIdentifier))
        return processObjects().filter { id in
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var addr = Self.address(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid) == noErr,
               appPIDs.contains(pid) || appPIDs.contains(Self.parent(of: pid)) { return true }
            var bid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            addr = Self.address(kAudioProcessPropertyBundleID)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &bid) == noErr,
                  let b = bid?.takeRetainedValue() as String? else { return false }
            return b.hasPrefix(app) || (webKit && b.hasPrefix("com.apple.WebKit"))
        }
    }

    private static func parent(of pid: pid_t) -> pid_t {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}
