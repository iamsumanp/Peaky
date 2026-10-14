import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shape

/// The notch silhouette: concave "ears" at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = max(0, min(bottomRadius, (rect.height - t) / 1, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// True only while the island is open, so hidden timelines (scrubber, marquee) stop ticking.
private struct IslandExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var islandExpanded: Bool {
        get { self[IslandExpandedKey.self] }
        set { self[IslandExpandedKey.self] = newValue }
    }
}

// MARK: - Island

/// Debug probe: the island width SwiftUI last laid out, and when.
enum RenderProbe {
    static var width: CGFloat = 0
    static var at = Date.distantPast
    static var bodyAt = Date.distantPast
    static var bodyPresentation = ""
}
private struct RenderedWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Every state is laid out once at its own final size and stays in the tree; changing state only animates
/// the black shape (which also clips) and fades layers in or out. Nothing gets built on hover, and nothing
/// re-lays-out while the shape is moving, so the animation keeps a steady frame rate.
struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let p = model.presentation
        let _ = { RenderProbe.bodyAt = Date(); RenderProbe.bodyPresentation = "\(p)" }()
        let size = model.size(for: p)
        let r = model.radii(for: p)
        let shape = NotchShape(topRadius: r.top, bottomRadius: r.bottom)
        let h = model.geo.notch.height
        let expandedSize = model.size(for: .expanded)

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            ZStack(alignment: .top) {
                layer(p == .pet, size: model.size(for: .pet)) {
                    // Centred in the strip to the right of the hardware notch.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PetView(kind: model.pet, hovering: model.hovering, active: p == .pet)
                            .frame(width: IslandModel.petEar, height: h)
                    }
                    .frame(height: h)
                }
                layer(p == .idle && model.caffeinated, size: model.size(for: .idle)) {
                    // No pet: the mug sits where the pet would.
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PixelMug().frame(width: IslandModel.petEar, height: h)
                    }
                    .frame(height: h)
                }
                layer(p == .status, size: model.size(for: .status)) {
                    StatusLiveView(model: model, height: h, active: p == .status)
                }
                layer(p == .music, size: model.size(for: .music)) {
                    MusicLiveView(model: model, height: h)
                }
                layer(p == .hud, size: model.size(for: .hud)) {
                    if let hud = model.lastHUD { HUDLiveView(hud: hud, height: h) }
                }
                layer(p == .notice, size: model.size(for: .notice)) {
                    if let n = model.lastNotice { NoticeView(notice: n, height: h, ear: IslandModel.noticeEar(n)) }
                }
                // Peek: interactive (its buttons), so it isn't a plain `layer`.
                let peekSize = model.size(for: .peek)
                PeekMusicView(model: model, height: h)
                    .frame(width: peekSize.width, height: peekSize.height, alignment: .top)
                    .opacity(p == .peek ? 1 : 0)
                    .animation(p == .peek ? .easeOut(duration: 0.2).delay(0.04) : .easeOut(duration: 0.08), value: p)
                    .allowsHitTesting(p == .peek)
                ExpandedView(model: model)
                    .frame(width: expandedSize.width, height: expandedSize.height, alignment: .top)
                    .environment(\.islandExpanded, p == .expanded)
                    .opacity(p == .expanded ? 1 : 0)
                    .scaleEffect(p == .expanded ? 1 : 0.92, anchor: .top)
                    .animation(p == .expanded ? .easeOut(duration: 0.22).delay(0.05) : .easeOut(duration: 0.1), value: p)
                    .allowsHitTesting(p == .expanded)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)

            if model.dropTargeted {
                shape.stroke(Theme.accent.opacity(0.8), lineWidth: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(GeometryReader { g in
            Color.clear.preference(key: RenderedWidthKey.self, value: g.size.width)
        })
        .onPreferenceChange(RenderedWidthKey.self) { w in
            RenderProbe.width = w
            RenderProbe.at = Date()
        }
        .contentShape(shape)
        .onTapGesture {
            switch p {
            case .expanded: break
            case .notice: model.dismissNotice()
            default: model.expand()
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $model.dropTargeted) { model.handleDrop($0) }
        .offset(x: model.xOffset(for: p))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(p == .expanded || p == .peek ? IslandModel.open : IslandModel.spring, value: p)
        .animation(IslandModel.spring, value: model.hovering)
        .environment(\.colorScheme, .dark)
    }

    /// A compact layer at its own fixed size; it fades with the state instead of being inserted/removed.
    private func layer<C: View>(_ visible: Bool, size: CGSize, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: size.width, height: size.height, alignment: .top)
            .opacity(visible ? 1 : 0)
            .animation(visible ? .easeOut(duration: 0.2).delay(0.04) : .easeOut(duration: 0.08), value: visible)
            .allowsHitTesting(false)
    }
}

// MARK: - Compact states

struct MusicLiveView: View {
    @ObservedObject var model: IslandModel
    let height: CGFloat
    @ObservedObject var np = Services.shared.nowPlaying

    var body: some View {
        HStack(spacing: 0) {
            // Something important (Claude waiting, a meeting) takes the left side; music keeps its bars.
            if let s = model.status {
                StatusSlot(item: s)
                    .padding(.leading, 12)
                    .frame(width: model.statusLeftEar, alignment: .leading)
            } else {
                ArtworkView(image: np.artwork, size: height - (height > 30 ? 14 : 8))
                    .padding(.leading, 10)
            }
            Spacer(minLength: 0)
            // With the left side taken, the artwork moves right, next to the bars.
            if model.status != nil {
                ArtworkView(image: np.artwork, size: IslandModel.artSize(height))
                    .padding(.trailing, 7)
            }
            Visualizer(playing: np.isPlaying, color: .white)
                .frame(width: 17, height: height * 0.38)
                .padding(.trailing, 12)
            if model.caffeinated { CupBadge() }
        }
        .frame(height: height)
    }
}

struct HUDLiveView: View {
    let hud: HUDState
    let height: CGFloat

    private var symbol: String {
        switch hud.kind {
        case .brightness: return hud.value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if hud.muted || hud.value == 0 { return "speaker.slash.fill" }
            if hud.value < 0.34 { return "speaker.wave.1.fill" }
            if hud.value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        let shown = hud.muted ? 0 : hud.value
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hud.kind == .brightness ? Color.yellow : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, alignment: .leading)
                .padding(.leading, 14)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // The original smooth bar (preferred to the segmented amber one here).
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(shown))
                    }
                }
                .frame(width: 40, height: 5)
                Text("\(Int((shown * 100).rounded()))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 18, alignment: .trailing)
            }
            .padding(.trailing, 12)
        }
        .frame(height: height)
    }
}

struct NoticeView: View {
    let notice: Notice
    let height: CGFloat
    let ear: CGFloat

    /// Levels ("100%") read as numbers.
    private var detailIsNumber: Bool {
        guard let d = notice.detail else { return false }
        return d.hasSuffix("%") && Int(d.dropLast()) != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                TileIcon(symbol: notice.symbol, tint: notice.tint, glyph: 9.5)
                    .frame(width: min(18, height - 6), height: min(18, height - 6))
                Text(notice.title)
                    .font(Theme.title(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            .frame(width: ear, alignment: .leading)
            Spacer(minLength: 0)
            if let d = notice.detail {
                Group {
                    if notice.pill {
                        Text(d)
                            .font(Theme.body(11.5, .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Theme.accent))
                    } else {
                        Text(d)
                            .font(detailIsNumber ? Theme.mono(11.5) : Theme.body(11.5, .medium))
                            .foregroundStyle(notice.detailTint)
                    }
                }
                .lineLimit(1)
                .padding(.trailing, notice.pill ? 8 : 14)
                .frame(width: ear, alignment: .trailing)
            }
        }
        .frame(height: height)
        .contentTransition(.opacity)
        .animation(IslandModel.spring, value: notice)
    }
}

/// Icon or colour bar, title (truncated), "· detail".
struct StatusSlot: View {
    let item: StatusItem
    /// Off when the time is shown on the other side of the notch.
    var showDetail = true

    var body: some View {
        // Keep Awake: just the mug — the time left lives on the ☕ button in the open island.
        if item.kind == .awake { PixelMug() } else { full }
    }

    private var full: some View {
        HStack(spacing: 5) {
            if item.kind == .awake {
                PixelMug().padding(.trailing, 1)
            } else if let sym = item.symbol {
                TileIcon(symbol: sym, tint: item.tint, glyph: 8.5)
                    .frame(width: 16, height: 16)
                .padding(.trailing, 1)
            } else if let bar = item.bar {
                RoundedRectangle(cornerRadius: 1).fill(bar).frame(width: 3, height: 14)
                    .padding(.trailing, 2)
            }
            Text(item.title)
                .font(Font(IslandModel.agendaTitleFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: item.titleMax, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if showDetail {
                Text("· " + item.detail)
                    .font(Font(IslandModel.agendaDetailFont))
                    .foregroundStyle(item.tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// The left slot on its own (nothing playing): status left of the notch, pet on the right.
struct StatusLiveView: View {
    @ObservedObject var model: IslandModel
    let height: CGFloat
    let active: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let s = model.status {
                if s.kind == .awake {
                    // Tucked up against the notch side of its slot.
                    StatusSlot(item: s)
                        .frame(width: model.statusLeftEar, height: height, alignment: .trailing)
                } else {
                    StatusSlot(item: s, showDetail: !model.statusSplit)
                        .padding(.leading, 12)
                        .frame(width: model.statusLeftEar, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            if let s = model.status, s.kind != .awake {
                // Meeting / Claude: the time on the right, no pet; the mug at the end if Keep Awake is on.
                if model.statusSplit {
                    Text(s.detail)
                        .font(Font(IslandModel.agendaDetailFont))
                        .foregroundStyle(s.tint)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 12)
                }
                if model.caffeinated { CupBadge() }
            } else if model.pet != .none {
                PetView(kind: model.pet, hovering: model.hovering, active: active)
                    .frame(width: IslandModel.petEar, height: height)
            }
        }
        .frame(height: height)
    }
}

/// One extra line in the peek / open panel: the status with its Join / Open button.
struct StatusLine: View {
    let item: StatusItem

    var body: some View {
        if let ask = item.ask { askLine(ask) } else { plain }
    }

    private var plain: some View {
        HStack(spacing: 8) {
            StatusSlot(item: item)
                .contentShape(Rectangle())
                .onTapGesture { item.open() }
            Spacer(minLength: 6)
            if item.kind == .meeting {
                ChipButton(label: "Hide", filled: false) {
                    let cal = Services.shared.calendar
                    if let e = cal.agenda ?? cal.upNext { withAnimation(IslandModel.spring) { cal.hide(e) } }
                }
                .help("Hide this meeting from the notch (left early?). It stays in your calendar.")
            }
            if let label = item.actionLabel {
                ChipButton(label: label, filled: true) { item.open() }
            }
        }
        .frame(height: IslandModel.statusLineHeight - 6)
    }

    /// Claude wants to run something: what, and Deny / Allow.
    private func askLine(_ ask: ClaudeAsk) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                TileIcon(symbol: item.symbol ?? "claude", tint: item.tint, glyph: 8.5)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Font(IslandModel.agendaTitleFont))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(ask.summary.isEmpty ? ask.tool : ask.tool + "  " + ask.summary)
                        .font(Theme.mono(10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { item.open() }
            .help(ask.summary.isEmpty ? "Open the session" : ask.summary)
            Spacer(minLength: 6)
            ChipButton(label: "Deny", filled: false) { ask.answer(allow: false) }
            ChipButton(label: "Allow", filled: true) { ask.answer(allow: true) }
        }
        .frame(height: 38)
    }
}

struct ChipButton: View {
    let label: String
    let filled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.body(11, .semibold))
                .foregroundStyle(filled ? Color.black : .white.opacity(hover ? 1 : 0.85))
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: Theme.tileRadius)
                    .fill(filled ? Theme.accent.opacity(hover ? 0.85 : 1) : Color.white.opacity(hover ? 0.18 : 0.1)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Peek (music, on hover)

/// Hovering the music activity: the compact row on top, then title + artist with prev / play / next.
/// Click anywhere else on it to open the full player.
struct PeekMusicView: View {
    @ObservedObject var model: IslandModel
    let height: CGFloat
    @ObservedObject var np = Services.shared.nowPlaying

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkView(image: np.artwork, size: height - (height > 30 ? 14 : 8))
                    .padding(.leading, 12)
                Spacer(minLength: 0)
                Visualizer(playing: np.isPlaying, color: .white)
                    .frame(width: 17, height: height * 0.38)
                    .padding(.trailing, 14)
            }
            .frame(height: height)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(np.title)
                        .font(Theme.title(13))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !np.subtitle.isEmpty {
                        Text(np.subtitle)
                            .font(Theme.body(11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                // Buttons consume their own clicks, so they never reach the island's tap-to-open.
                HStack(spacing: 2) {
                    PixelButton(symbol: "backward.fill", size: 30, iconSize: 10, filled: false) { np.previous() }
                    PixelButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 32, iconSize: 12, filled: true) { np.togglePlayPause() }
                    PixelButton(symbol: "forward.fill", size: 30, iconSize: 10, filled: false) { np.next() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            if model.showsStatusLine, let s = model.status {
                StatusLine(item: s)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Square-ish 4pt-corner button. `filled` gets the rgba(255,255,255,0.1) plate (play/pause).
struct PixelButton: View {
    let symbol: String
    let size: CGFloat
    let iconSize: CGFloat
    let filled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.tileRadius)
                    .fill(Color.white.opacity(filled ? (hover ? 0.16 : 0.1) : (hover ? 0.08 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Expanded

/// The open island. Swipe sideways for the shelf.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // The meeting line below already has its own Join button.
                if !(model.showsStatusLine && model.status?.kind == .meeting) { JoinChip() }
                Spacer()
                AwakeButton()
                ShelfSwitch(model: model)
            }
            .padding(.horizontal, 16)
            .frame(height: model.geo.notch.height)
            Group {
                switch model.tab {
                case .home:
                    VStack(spacing: 6) {
                        PlayerRow(open: model.expanded)
                        if model.showsStatusLine, let s = model.status { StatusLine(item: s) }
                    }
                case .shelf: ShelfView(model: model)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct PlayerRow: View {
    /// The open island is always laid out (only faded), so anything that ticks must stop while it's closed.
    var open = true
    @ObservedObject var np = Services.shared.nowPlaying

    var body: some View {
        if np.hasMedia {
            VStack(spacing: 6) {
                player
                if np.duration > 1 { Scrubber(ticking: open) }
            }
        } else {
            IdleRow()
        }
    }

    private var player: some View {
            HStack(spacing: 12) {
                    ArtworkView(image: np.artwork, size: 56)
                        .overlay(alignment: .bottomTrailing) {
                            if let icon = np.appIcon {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16).offset(x: 4, y: 4)
                            }
                        }
                        .onTapGesture { np.openSourceApp() }
                    VStack(alignment: .leading, spacing: 3) {
                        MarqueeText(text: np.title, font: Theme.title(15))
                            .foregroundStyle(.white)
                        if !np.subtitle.isEmpty {
                            Text(np.subtitle)
                                .font(Theme.body(12))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        PixelButton(symbol: "backward.fill", size: 36, iconSize: 13, filled: false) { np.previous() }
                        PixelButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 40, iconSize: 16, filled: true) { np.togglePlayPause() }
                        PixelButton(symbol: "forward.fill", size: 36, iconSize: 13, filled: false) { np.next() }
                    }
            }
    }
}

/// `1:12 ━━━━●──── 3:45` — how far into the track; click or drag to jump.
struct Scrubber: View {
    /// Only while the island is open: a hidden bar ticking twice a second cost ~1–2 % CPU all day.
    var ticking = true
    @ObservedObject var np = Services.shared.nowPlaying
    /// While dragging: where the knob is (0…1); the track only seeks when you let go.
    @State private var dragging: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !ticking)) { ctx in
            let d = max(np.duration, 1)
            let f = dragging ?? min(max(np.elapsed(at: ctx.date) / d, 0), 1)
            HStack(spacing: 8) {
                Text(Self.time(f * d))
                    .frame(width: 38, alignment: .trailing)
                GeometryReader { g in
                    let w = g.size.width
                    let active = hover || dragging != nil
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15)).frame(height: active ? 5 : 3)
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: max(3, w * f), height: active ? 5 : 3)
                        Circle().fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: w * f - 5)
                            .opacity(active ? 1 : 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = min(max(v.location.x / max(w, 1), 0), 1) }
                        .onEnded { v in
                            np.seek(to: min(max(v.location.x / max(w, 1), 0), 1) * d)
                            dragging = nil
                        })
                    .animation(.easeOut(duration: 0.12), value: active)
                }
                .onHover { hover = $0 }
                Text(Self.time(d))
                    .frame(width: 38, alignment: .leading)
            }
            .font(Theme.mono(10))
            .foregroundStyle(.white.opacity(0.5))
            .monospacedDigit()
        }
        .frame(height: IslandModel.scrubberHeight - 6)
    }

    /// 75 → "1:15", 3725 → "1:02:05".
    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down)), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Top-right of the open island: tray (with file count) → shelf; house → back to the normal view.
struct ShelfSwitch: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var shelf = Services.shared.shelf
    @State private var hover = false

    var body: some View {
        let onShelf = model.tab == .shelf
        Button {
            withAnimation(IslandModel.spring) { model.tab = onShelf ? .home : .shelf }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: onShelf ? "house.fill" : "tray.fill")
                    .font(.system(size: 10, weight: .semibold))
                if !onShelf && !shelf.items.isEmpty {
                    Text("\(shelf.items.count)").font(Theme.mono(10))
                }
            }
            .foregroundStyle(.white.opacity(hover ? 0.9 : 0.6))
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Color.white.opacity(hover ? 0.14 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(onShelf ? "Back" : "Shelf")
    }
}

/// Sits in the open panel's left ear while a meeting with a call link is about to start or running.
struct JoinChip: View {
    @ObservedObject var cal = Services.shared.calendar

    var body: some View {
        if let e = cal.joinable, let url = e.joinURL {
            Button { NSWorkspace.shared.open(url) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill").font(.system(size: 9, weight: .semibold))
                    Text("Join").font(Theme.body(11, .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Theme.tileRadius).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help(e.title)
        }
    }
}

/// Nothing playing: today's date and the next event.
struct IdleRow: View {
    @ObservedObject var cal = Services.shared.calendar

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(Date.now.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(Theme.title(10))
                    .foregroundStyle(Theme.accent)
                Text(Date.now.formatted(.dateTime.day()))
                    .font(Theme.mono(22, .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40)
            Group {
                if let e = cal.events.first(where: { !cal.isHidden($0) }) {
                    EventRow(event: e, onHide: e.soonOrNow ? { withAnimation(IslandModel.spring) { cal.hide(e) } } : nil)
                } else if !cal.authorized && !cal.denied {
                    Button("Connect Calendar") { cal.requestAccess() }
                        .buttonStyle(.plain)
                        .font(Theme.body(11.5, .medium))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("Nothing playing").font(Theme.body(12)).foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 56)
    }
}


struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var corner: CGFloat = Theme.tileRadius

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

/// Little equaliser bars. Pure decoration — driven by time, not audio.
/// Animated by Core Animation in the render server, so it costs Peaky nothing per frame (a SwiftUI
/// timeline here re-laid-out the whole island 20× a second, ~8% CPU while music played).
struct Visualizer: NSViewRepresentable {
    let playing: Bool
    let color: Color

    func makeNSView(context: Context) -> BarsView { BarsView() }
    func updateNSView(_ v: BarsView, context: Context) { v.update(playing: playing, color: NSColor(color)) }

    final class BarsView: NSView {
        private var bars: [CALayer] = []
        private var playing = false
        private let durations: [CFTimeInterval] = [0.42, 0.31, 0.53, 0.37]
        private let lows: [CGFloat] = [0.25, 0.35, 0.2, 0.3]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for _ in 0..<4 {
                let l = CALayer()
                l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer?.addSublayer(l)
                bars.append(l)
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let gap: CGFloat = 2.5
            let w = (bounds.width - gap * 3) / 4
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, l) in bars.enumerated() {
                l.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
                l.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
                l.cornerRadius = 1 // pixel style: square-ish blocks
            }
            CATransaction.commit()
            if playing { animate() }
        }

        func update(playing: Bool, color: NSColor) {
            bars.forEach { $0.backgroundColor = color.cgColor }
            guard playing != self.playing else { return }
            self.playing = playing
            playing ? animate() : rest()
        }

        private func animate() {
            for (i, l) in bars.enumerated() {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = lows[i]
                a.toValue = 1.0
                a.duration = durations[i]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.13
                l.add(a, forKey: "bounce")
            }
        }

        private func rest() {
            for l in bars {
                l.removeAnimation(forKey: "bounce")
                l.transform = CATransform3DMakeScale(1, 0.18, 1)
            }
        }
    }
}

/// Scrolls the text horizontally when it doesn't fit.
struct MarqueeText: View {
    let text: String
    let font: Font
    @Environment(\.islandExpanded) private var active
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let overflow = textWidth > g.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !overflow || !active)) { ctx in
                let gap: CGFloat = 40
                let cycle = Double(textWidth + gap) / 30 + 2 // 30 pt/s plus a 2s rest
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
                let offset = overflow ? -CGFloat(max(0, t - 2) * 30) : 0
                HStack(spacing: gap) {
                    Text(text).font(font).fixedSize()
                        .background(GeometryReader { tg in Color.clear.onAppear { textWidth = tg.size.width }
                            .onChange(of: text) { textWidth = tg.size.width } })
                    if overflow { Text(text).font(font).fixedSize() }
                }
                .offset(x: offset)
            }
            .frame(width: g.size.width, alignment: .leading)
            .clipped()
            .mask(LinearGradient(stops: overflow ? [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.92), .init(color: .clear, location: 1),
            ] : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 20)
    }
}

// MARK: - Calendar

struct EventRow: View {
    let event: CalEvent
    /// For the meeting that's on now (or about to be): hide it from the notch, e.g. after leaving early.
    var onHide: (() -> Void)? = nil
    @State private var hover = false

    private var timeText: String {
        let cal = Calendar.current
        let prefix = cal.isDateInToday(event.start) || event.start < Date() ? "" : "Tomorrow "
        if event.allDay { return prefix + "All day" }
        let mins = Int(event.start.timeIntervalSinceNow / 60)
        if event.isNow { return "Now · " + event.relative }
        if mins < 12 * 60 && prefix.isEmpty { return "In " + CalEvent.span(event.start.timeIntervalSinceNow) }
        return prefix + event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(event.color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(Theme.title(12)).foregroundStyle(.white).lineLimit(1)
                Text(timeText).font(Theme.mono(10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            if let onHide {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(hover ? 0.9 : 0.45))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.08)))
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .help("Hide from the notch (left early?). It stays in your calendar.")
            }
        }
        .contextMenu {
            if let onHide { Button("Hide from the Notch", action: onHide) }
        }
    }
}

/// A symbol in a softly tinted tile — except "claude", which is Claude's own spark, bare, in Claude orange.
struct TileIcon: View {
    let symbol: String
    let tint: Color
    let glyph: CGFloat

    var body: some View {
        if symbol == "claude" {
            ClaudeMark().foregroundStyle(tint)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.tileRadius).fill(tint.opacity(0.22))
                Image(systemName: symbol).font(.system(size: glyph, weight: .bold)).foregroundStyle(tint)
            }
        }
    }
}

/// Claude's spark, taken from the installed Claude app's menu-bar icon (a template image, so it takes any tint).
/// Falls back to the SF sparkle if Claude.app isn't there.
struct ClaudeMark: View {
    static let image: NSImage? = {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop")
            ?? URL(fileURLWithPath: "/Applications/Claude.app")
        let res = app.appendingPathComponent("Contents/Resources")
        for name in ["TrayIconTemplate@3x.png", "TrayIconTemplate@2x.png", "TrayIconTemplate.png"] {
            if let img = NSImage(contentsOf: res.appendingPathComponent(name)) { img.isTemplate = true; return img }
        }
        return nil
    }()

    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "sparkle").resizable().aspectRatio(contentMode: .fit).fontWeight(.bold).padding(2)
        }
    }
}
