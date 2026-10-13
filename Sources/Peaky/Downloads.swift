import AppKit
import Combine

/// Files downloading into ~/Downloads. Safari, Chrome, Arc, Firefox… publish their progress on the file
/// (it's what draws Finder's progress bars); subscribing to the folder gets every one of them.
final class DownloadsMonitor: ObservableObject {
    struct Item: Equatable {
        let id: ObjectIdentifier
        let name: String
        var fraction: Double?   // nil = size not known yet
    }

    /// Updated at most a few times a second, and only when a whole percent changes.
    @Published private(set) var items: [Item] = []

    private var subscriber: Any?
    private var live: [ObjectIdentifier: (progress: Progress, name: String, url: URL?, watch: NSKeyValueObservation)] = [:]
    private var pending = false

    func start() {
        guard subscriber == nil,
              let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        subscriber = Progress.addSubscriber(forFileURL: dir) { [weak self] progress in
            let id = ObjectIdentifier(progress)
            let url = progress.fileURL ?? progress.userInfo[.fileURLKey] as? URL
            DispatchQueue.main.async { self?.add(progress, id: id, url: url) }
            return { DispatchQueue.main.async { self?.finish(id) } }
        }
    }

    /// "report.pdf.crdownload" → "report.pdf".
    static func cleanName(_ url: URL?) -> String {
        guard var name = url?.lastPathComponent else { return "Download" }
        for ext in [".crdownload", ".download", ".part", ".partial"] where name.hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return name
    }

    private func add(_ progress: Progress, id: ObjectIdentifier, url: URL?) {
        guard live[id] == nil else { return }
        let watch = progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.schedule() }
        }
        live[id] = (progress, Self.cleanName(url), url, watch)
        schedule()
    }

    private func finish(_ id: ObjectIdentifier) {
        guard let entry = live.removeValue(forKey: id) else { return }
        entry.watch.invalidate()
        publish()
        // Finished (not cancelled): one short "Downloaded" alert; clicking it shows the file in Finder.
        guard !entry.progress.isCancelled, entry.progress.fractionCompleted > 0.99 || entry.progress.isFinished else { return }
        var done = Notice(key: "download-done", symbol: "arrow.down.circle.fill", tint: Theme.level, title: entry.name,
                          detail: "Downloaded", detailTint: Theme.level, duration: 3)
        let finalURL = entry.url.map { u -> URL in
            let clean = u.deletingLastPathComponent().appendingPathComponent(entry.name)
            return FileManager.default.fileExists(atPath: clean.path) ? clean : u
        }
        if let finalURL { done.revealURL = finalURL }
        IslandHub.post(.notice(done))
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pending = false
            self?.publish()
        }
    }

    private func publish() {
        let next = live.map { id, e -> Item in
            let p = e.progress
            let known = p.totalUnitCount > 0 && !p.isIndeterminate
            return Item(id: id, name: e.name, fraction: known ? (p.fractionCompleted * 100).rounded() / 100 : nil)
        }
        .sorted { $0.name < $1.name }
        if next != items { items = next }
    }
}
