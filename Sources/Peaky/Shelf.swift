import AppKit
import Quartz
import SwiftUI

// MARK: - Shelf

/// The shelf tab of the open island: a bar (count, select all, drag, AirDrop, remove) over a Finder-like
/// grid — scroll, ⌘A, click / ⇧ / ⌘-click, drag a box to select, Space for Quick Look, Delete removes,
/// drag out carries the selection.
struct ShelfView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var shelf = Services.shared.shelf
    @StateObject private var sel = ShelfSelection()

    /// What the bar acts on: the selection, or everything when nothing is selected.
    private var targets: [URL] {
        let s = shelf.items.filter(sel.urls.contains)
        return s.isEmpty ? shelf.items : s
    }

    var body: some View {
        if shelf.items.isEmpty {
            RoundedRectangle(cornerRadius: Theme.tileRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(model.dropTargeted ? Theme.accent : .white.opacity(0.25))
                .overlay {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 15))
                            .symbolEffect(.bounce, value: model.dropTargeted)
                        Text(model.dropTargeted ? "Drop to keep it here" : "Drop files on the notch to keep them handy")
                            .font(Theme.body(11.5, .medium))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
        } else {
            VStack(spacing: 6) {
                bar
                ShelfGrid(items: shelf.items, sel: sel)
                    .frame(height: model.shelfGridHeight(width: model.size(for: .expanded).width))
            }
        }
    }

    private var bar: some View {
        let n = sel.urls.count, all = shelf.items.count
        let selecting = n > 0
        return HStack(spacing: 6) {
            Text(selecting ? "\(n) of \(all) selected" : "\(all) file\(all == 1 ? "" : "s")")
                .font(Theme.body(11, .medium))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
            Spacer(minLength: 4)
            BarChip(label: n == all ? "Deselect" : "Select all", help: "⌘A selects all · Esc deselects") {
                n == all ? sel.clear() : sel.selectAll()
            }
            BarChip(symbol: "airplayaudio", help: selecting ? "AirDrop the selected files" : "AirDrop everything") {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: targets)
            }
            BarChip(symbol: "trash", label: selecting ? "Remove \(n)" : "Remove all", destructive: true,
                    help: "Takes them off the shelf (your files stay where they are) · Delete key works too") {
                let gone = targets
                sel.clear()
                withAnimation { gone.forEach(shelf.remove) }
            }
        }
        .frame(height: IslandModel.shelfBarHeight)
    }
}

/// A small button in the shelf bar. With `urls`, it's a drag handle instead (drag it out to take those files).
struct BarChip: View {
    var symbol: String? = nil
    var label: String? = nil
    var destructive = false
    var help: String
    var urls: (() -> [URL])? = nil
    var action: () -> Void = {}
    @State private var hover = false

    var body: some View {
        let content = HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            if let label { Text(label).font(Theme.body(10.5, .semibold)) }
        }
        .foregroundStyle(destructive && hover ? Color(red: 1, green: 0.45, blue: 0.42) : .white.opacity(hover ? 1 : 0.8))
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Color.white.opacity(hover ? 0.16 : 0.08)))
        .contentShape(Rectangle())
        .help(help)

        if let urls {
            content.overlay(FileDragSource(urls: urls, onHover: { hover = $0 }))
        } else {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
        }
    }
}

/// Selection shared between the grid (AppKit) and the bar (SwiftUI).
final class ShelfSelection: ObservableObject {
    @Published fileprivate(set) var urls = Set<URL>()
    fileprivate weak var view: ShelfCollectionView?

    func selectAll() { view?.selectAll(nil); view?.takeKeyboard() }
    func clear() { view?.deselectAll(nil) }
}

// MARK: - Grid (NSCollectionView)

struct ShelfGrid: NSViewRepresentable {
    let items: [URL]
    let sel: ShelfSelection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = IslandModel.shelfTile
        layout.minimumInteritemSpacing = IslandModel.shelfGap
        layout.minimumLineSpacing = IslandModel.shelfGap
        layout.sectionInset = NSEdgeInsetsZero

        let cv = ShelfCollectionView()
        cv.collectionViewLayout = layout
        cv.backgroundColors = [.clear]
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.register(ShelfCell.self, forItemWithIdentifier: ShelfCell.id)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        // Copies out of Peaky, never moves; nothing when dropped back on the island itself.
        cv.setDraggingSourceOperationMask(.copy, forLocal: false)
        cv.setDraggingSourceOperationMask([], forLocal: true)
        cv.items = { [weak coordinator = context.coordinator] in coordinator?.items ?? [] }
        cv.onSelection = { [weak sel] urls in if sel?.urls != urls { sel?.urls = urls } }
        sel.view = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.verticalScrollElasticity = .allowed
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let cv = scroll.documentView as? ShelfCollectionView else { return }
        sel.view = cv
        let c = context.coordinator
        if c.items != items {
            let keep = sel.urls.intersection(items)
            c.items = items
            cv.reloadData()
            cv.selectionIndexPaths = Set(items.enumerated().filter { keep.contains($0.element) }
                .map { IndexPath(item: $0.offset, section: 0) })
        }
        // Stretch the tiles so the columns fill the width.
        if let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout {
            let w = scroll.contentSize.width, gap = IslandModel.shelfGap
            let cols = max(1, Int((w + gap) / (IslandModel.shelfTile.width + gap)))
            let tile = floor((w - CGFloat(cols - 1) * gap) / CGFloat(cols))
            if w > 0, abs(layout.itemSize.width - tile) > 0.5 {
                layout.itemSize = CGSize(width: tile, height: IslandModel.shelfTile.height)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.window as? NotchPanel)?.giveBackKeyboard()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var items: [URL] = []

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) {
            (cv as? ShelfCollectionView)?.selectionChanged()
        }
        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) {
            (cv as? ShelfCollectionView)?.selectionChanged()
        }

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: ShelfCell.id, for: ip)
            if let c = cell as? ShelfCell {
                c.show(items[ip.item])
                c.onRemove = { url in withAnimation { Services.shared.shelf.remove(url) } }
            }
            return cell
        }

        func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
            items.indices.contains(ip.item) ? items[ip.item] as NSURL : nil
        }
    }
}

final class ShelfCollectionView: NSCollectionView {
    var items: () -> [URL] = { [] }
    var onSelection: (Set<URL>) -> Void = { _ in }

    /// Tell the bar. Clicks and boxes come via the delegate; ⌘A, Esc and code come via the overrides below.
    func selectionChanged() {
        let urls = Set(selectedURLs)
        DispatchQueue.main.async { [weak self] in self?.onSelection(urls) }
        if quickLookOpen { QLPreviewPanel.shared().reloadData() }
    }

    // MARK: Quick Look (Space)

    /// While Quick Look is up the island stays open (moving the mouse to the preview would otherwise close it).
    static var quickLookVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
    private var quickLookOpen = false

    func toggleQuickLook() {
        if Self.quickLookVisible { QLPreviewPanel.shared().orderOut(nil); return }
        if selectionIndexPaths.isEmpty, !items().isEmpty { selectionIndexPaths = [IndexPath(item: 0, section: 0)] }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookOpen = true
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        quickLookOpen = false
        panel.dataSource = nil
        panel.delegate = nil
        // Now the island may close if the mouse has moved away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppDelegate.shared.controllers.forEach { $0.collapseIfMouseLeft() } }
    }
    override var selectionIndexPaths: Set<IndexPath> { didSet { selectionChanged() } }
    override func selectAll(_ sender: Any?) { super.selectAll(sender); selectionChanged() }
    override func deselectAll(_ sender: Any?) { super.deselectAll(sender); selectionChanged() }

    private var selectedURLs: [URL] {
        let all = items()
        return selectionIndexPaths.map(\.item).sorted().filter(all.indices.contains).map { all[$0] }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Keyboard (⌘A, Delete, Esc) only after you click in the shelf; given back when the island closes.
    func takeKeyboard() {
        (window as? NotchPanel)?.takeKeyboard()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        takeKeyboard()
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, let ip, items().indices.contains(ip.item) {
            NSWorkspace.shared.open(items()[ip.item])
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: removeSelected()                       // Delete, Forward Delete
        case 53:                                             // Esc: deselect, then close
            if selectionIndexPaths.isEmpty { AppDelegate.shared.controllers.forEach { $0.model.collapse() } }
            else { deselectAll(nil) }
        case 49: toggleQuickLook()                           // Space
        case 36, 76: selectedURLs.forEach { NSWorkspace.shared.open($0) }   // Return
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                selectAll(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func removeSelected() {
        let gone = selectedURLs
        guard !gone.isEmpty else { return }
        deselectAll(nil)
        withAnimation { gone.forEach(Services.shared.shelf.remove) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        takeKeyboard()
        return buildMenu(for: event)
    }

    private func buildMenu(for event: NSEvent) -> NSMenu {
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            return FileDragSource.menu([("Select All", { [weak self] in self?.selectAll(nil) })])
        }
        // Right-clicking outside the selection acts on that file alone, like Finder.
        if !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
        }
        let urls = selectedURLs
        let n = urls.count
        return FileDragSource.menu([
            (n > 1 ? "Open \(n) Files" : "Open", { urls.forEach { NSWorkspace.shared.open($0) } }),
            ("Quick Look", { [weak self] in self?.toggleQuickLook() }),
            ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting(urls) }),
            (n > 1 ? "Remove \(n) from Shelf" : "Remove from Shelf", { [weak self] in self?.removeSelected() }),
            ("Select All", { [weak self] in self?.selectAll(nil) }),
        ])
    }
}

extension ShelfCollectionView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let urls = selectedURLs
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
    /// Space / Esc inside the preview close it; arrows move through the selection.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 { panel.orderOut(nil); return true }
        return false
    }
}

/// A tile's background view: tells the cell when the mouse is over it.
final class ShelfCellView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

final class ShelfCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var url: URL?
    private var hovering = false { didSet { refresh() } }
    var onRemove: (URL) -> Void = { _ in }

    override func loadView() {
        let v = ShelfCellView()
        v.onHover = { [weak self] in self?.hovering = $0 }
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Shelf")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.white, .systemGray])))
        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.toolTip = "Remove from Shelf"
        removeButton.isHidden = true
        v.wantsLayer = true
        v.layer?.cornerRadius = Theme.tileRadius
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        v.addSubview(icon)
        v.addSubview(label)
        v.addSubview(removeButton)
        view = v
        refresh()
    }

    @objc private func removeTapped() { if let url { onRemove(url) } }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        icon.frame = NSRect(x: (b.width - 32) / 2, y: b.height - 5 - 32, width: 32, height: 32)
        let w = min(b.width - 4, label.intrinsicContentSize.width + 8)
        label.frame = NSRect(x: (b.width - w) / 2, y: 4, width: w, height: 14)
        removeButton.frame = NSRect(x: b.width - 17, y: b.height - 17, width: 16, height: 16)
    }

    func show(_ url: URL) {
        self.url = url
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        label.stringValue = url.lastPathComponent
        view.toolTip = url.path
        view.needsLayout = true
    }

    override var isSelected: Bool { didSet { refresh() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { refresh() } }

    private func refresh() {
        guard isViewLoaded else { return }
        let on = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        let accent = NSColor(Theme.accent)
        view.layer?.backgroundColor = on ? accent.withAlphaComponent(0.18).cgColor
            : NSColor.white.withAlphaComponent(hovering ? 0.08 : 0).cgColor
        removeButton.isHidden = !hovering
        label.layer?.backgroundColor = on ? accent.cgColor : NSColor.clear.cgColor
        label.textColor = on ? .black : NSColor.white.withAlphaComponent(0.8)
    }
}

/// A right-click menu hangs outside the island, so moving onto it looked like leaving and the island closed
/// under the menu. While one is open the island stays; when it closes, it may close if the mouse has gone.
enum IslandMenu {
    private static var open = 0
    static var isOpen: Bool { open > 0 }

    /// Watches every menu Peaky shows (the shelf's, the ☕ button's durations, the menu-bar one).
    static func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in open += 1 }
        nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            open = max(0, open - 1)
            // After the chosen item has run (Quick Look keeps the island open by itself).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !isOpen else { return }
                AppDelegate.shared.controllers.forEach { $0.collapseIfMouseLeft() }
            }
        }
    }
}

// MARK: - Drag handle

/// AppKit mouse handling for the bar's Drag handle: a drag that carries many files at once
/// (SwiftUI's onDrag only carries one).
struct FileDragSource: NSViewRepresentable {
    var urls: () -> [URL]
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ v: SourceView, context: Context) { v.parent = self }

    static func menu(_ entries: [(String, () -> Void)]) -> NSMenu {
        let m = NSMenu()
        for (title, run) in entries {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action   // keeps the closure alive
            m.addItem(item)
        }
        return m
    }

    final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    final class SourceView: NSView, NSDraggingSource {
        var parent: FileDragSource?
        private var down: NSEvent?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { parent?.onHover(true) }
        override func mouseExited(with event: NSEvent) { parent?.onHover(false) }

        override func mouseDown(with event: NSEvent) { down = event; dragging = false }

        override func mouseDragged(with event: NSEvent) {
            guard let down, !dragging, let parent else { return }
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            let urls = parent.urls()
            guard !urls.isEmpty else { return }
            dragging = true
            let p = convert(a, from: nil)
            let items: [NSDraggingItem] = urls.enumerated().map { i, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let off = CGFloat(min(i, 4)) * 3
                item.setDraggingFrame(NSRect(x: p.x - 16 + off, y: p.y - 16 - off, width: 32, height: 32),
                                      contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            let session = beginDraggingSession(with: items, event: down, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) { down = nil }

        // Copies, never moves: the shelf only holds references to your files.
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
