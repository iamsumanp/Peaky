import SwiftUI

/// A tiny pixel pet that sits beside the notch while nothing else is happening.
enum PetKind: String, CaseIterable, Identifiable {
    case none, cat, dog, bunny
    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: return "None"
        case .cat: return "Cat"
        case .dog: return "Dog"
        case .bunny: return "Bunny"
        }
    }
    var sprite: PetSprite? {
        switch self {
        case .none: return nil
        case .cat: return .cat
        case .dog: return .dog
        case .bunny: return .bunny
        }
    }
}

/// 13×12 pixel grids. `alt` replaces some rows for the idle fidget (tail swish / ear flop).
/// 'E' cells are eyes; they turn into `lid` when blinking or asleep.
struct PetSprite {
    let rows: [String]
    let alt: [Int: String]
    let palette: [Character: Color]
    let lid: Color

    static let width = 13
    static let height = 12

    func frame(fidget: Bool) -> [[Character]] {
        rows.enumerated().map { i, r in Array(fidget ? (alt[i] ?? r) : r) }
    }

    static let cat = PetSprite(
        rows: [
            "..B.....B....",
            "..BP...PB....",
            "..BBDBDBB....",
            ".BBBBBBBBB...",
            ".BEBBBBBEB...",
            ".BBBBPBBBB...",
            "..BBBBBBB....",
            "..BWWWWWB..D.",
            ".BBWWWWWBB.B.",
            ".BBWWWWWBBB..",
            ".BBBBBBBBB...",
            "..BB...BB....",
        ],
        alt: [
            6: "..BBBBBBB..D.",
            7: "..BWWWWWB.B..",
            8: ".BBWWWWWBBB..",
            9: ".BBWWWWWBB...",
        ],
        palette: ["B": Color(hex: 0xF4A259), "D": Color(hex: 0xC76B2F), "W": Color(hex: 0xFFF1DC),
                  "E": Color(hex: 0x2B2B2B), "P": Color(hex: 0xF49AB0)],
        lid: Color(hex: 0xC76B2F))

    static let dog = PetSprite(
        rows: [
            "...BBBBB.....",
            "..BBBBBBB....",
            ".DBBBBBBBD...",
            ".DBEBBBEBD...",
            ".DBBBBBBBD...",
            ".DDBWNWBDD...",
            "..DBWWWBD....",
            "..BBWWWBB..B.",
            ".BBBWWWBBB.B.",
            ".BBBWWWBBBB..",
            ".BBBBBBBBB...",
            "..WW...WW....",
        ],
        alt: [
            6: "..DBWWWBD...B",
            7: "..BBWWWBB..B.",
            8: ".BBBWWWBBBB..",
        ],
        palette: ["B": Color(hex: 0xD9A066), "D": Color(hex: 0x7A4A2A), "W": Color(hex: 0xFFF6E8),
                  "E": Color(hex: 0x222222), "N": Color(hex: 0x222222)],
        lid: Color(hex: 0x7A4A2A))

    static let bunny = PetSprite(
        rows: [
            "..BB...BB....",
            "..BP...PB....",
            "..BP...PB....",
            "..BBBBBBB....",
            ".BBBBBBBBB...",
            ".BBEBBBEBB...",
            ".BBBBPBBBB...",
            "..BBBBBBB....",
            ".BBBBBBBBB...",
            ".BBBBBBBBBTT.",
            ".BBBBBBBBBTT.",
            "..BB...BB....",
        ],
        alt: [
            0: ".......BB....",
            1: "BBB....PB....",
            2: "..BB...PB....",
        ],
        palette: ["B": Color(hex: 0xE9E6E1), "P": Color(hex: 0xF5A3B7), "E": Color(hex: 0x333333),
                  "T": Color.white],
        lid: Color(hex: 0xB9B5AE))
}

/// The pet on screen. Frames are pre-rendered once and flipped by Core Animation in the render server,
/// so an idle pet costs Peaky nothing per frame (a SwiftUI timeline here re-laid-out the whole island 4×/s).
struct PetView: View {
    let kind: PetKind
    let hovering: Bool
    /// Only animate while the pet is actually on screen.
    var active = true

    @State private var hop = false

    var body: some View {
        PetSpriteView(kind: kind, hovering: hovering, active: active)
            .frame(width: CGFloat(PetSpriteView.canvasW) * PetSpriteView.px,
                   height: CGFloat(PetSpriteView.canvasH) * PetSpriteView.px)
            .offset(y: hop ? -3 : 0)
            .onChange(of: hovering) {
                guard hovering else { return }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { hop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hop = false }
                }
            }
    }
}

struct PetSpriteView: NSViewRepresentable {
    static let px: CGFloat = 1.5
    /// Sprite plus a 3-pixel margin on top/right for the sleeping "z".
    static let canvasW = PetSprite.width + 3 + 1
    static let canvasH = PetSprite.height + 3

    let kind: PetKind
    let hovering: Bool
    let active: Bool

    func makeNSView(context: Context) -> SpriteView { SpriteView() }
    func updateNSView(_ v: SpriteView, context: Context) { v.configure(kind: kind, hovering: hovering, active: active) }

    final class SpriteView: NSView {
        private let sprite = CALayer()
        private var kind: PetKind = .none
        private var active = false
        private var asleep = false
        private var sleepWork: DispatchWorkItem?
        private var frames: [String: CGImage] = [:]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            sprite.magnificationFilter = .nearest
            sprite.contentsGravity = .resize
            layer?.addSublayer(sprite)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.frame = bounds
            CATransaction.commit()
        }

        func configure(kind: PetKind, hovering: Bool, active: Bool) {
            var restart = false
            if kind != self.kind { self.kind = kind; frames = render(kind); restart = true }
            if active != self.active { self.active = active; restart = true }
            if hovering, asleep { asleep = false; restart = true }
            if hovering || restart { scheduleSleep() }
            if restart { play() }
        }

        /// Nap after 30 s of nothing; hovering wakes it.
        private func scheduleSleep() {
            sleepWork?.cancel()
            guard active else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.active else { return }
                self.asleep = true
                self.play()
                CATransaction.flush() // from a timer: push it to the screen ourselves
            }
            sleepWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
        }

        private func play() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.removeAllAnimations()
            sprite.contents = frames["idle"]
            if active, !frames.isEmpty {
                let a = CAKeyframeAnimation(keyPath: "contents")
                a.calculationMode = .discrete
                a.repeatCount = .infinity
                if asleep {
                    // Slow breathing with a "z" drifting up.
                    a.values = (0..<8).map { frames["sleep\($0)"]! }
                    a.duration = 2.4
                } else {
                    // 18 steps of 0.25 s: blink once, swish the tail once.
                    var seq = Array(repeating: frames["idle"]!, count: 18)
                    seq[0] = frames["blink"]!
                    for i in 7...9 { seq[i] = frames["fidget"]! }
                    a.values = seq
                    a.duration = 4.5
                }
                sprite.add(a, forKey: "frames")
            }
            CATransaction.commit()
            // No CATransaction.flush() here: this runs inside SwiftUI's update when the island opens,
            // and flushing mid-update cut the open animation off until the next event.
        }

        /// Pre-renders every frame the pet needs into small bitmaps (one pixel per sprite cell).
        private func render(_ kind: PetKind) -> [String: CGImage] {
            guard let sp = kind.sprite else { return [:] }
            func image(fidget: Bool, eyesClosed: Bool, squash: Bool, z: Int?) -> CGImage? {
                let w = PetSpriteView.canvasW, h = PetSpriteView.canvasH
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                // CG's origin is bottom-left; sprite rows are listed top-down, sitting on the bottom edge.
                let rows = sp.frame(fidget: fidget)
                for (y, row) in rows.enumerated() {
                    // A squashed breath drops the top row of the sprite by one pixel.
                    if squash && y == 0 { continue }
                    for (x, c) in row.enumerated() where c != "." {
                        let color = c == "E" && eyesClosed ? sp.lid : (sp.palette[c] ?? .clear)
                        ctx.setFillColor(NSColor(color).cgColor)
                        let cy = PetSprite.height - 1 - y - (squash ? 0 : 0)
                        ctx.fill(CGRect(x: x, y: cy, width: 1, height: 1))
                    }
                }
                if let z {
                    // A tiny, faint "z" drifting up above the right ear and fading out.
                    ctx.setFillColor(NSColor.white.withAlphaComponent([0.45, 0.35, 0.22, 0.1][min(z, 3)]).cgColor)
                    let baseY = PetSprite.height - 3 + min(z, 3)
                    let x0 = PetSprite.width
                    for (dx, dy) in [(0, 2), (1, 2), (2, 2), (1, 1), (0, 0), (1, 0), (2, 0)] {
                        ctx.fill(CGRect(x: x0 + dx, y: baseY + dy - 2, width: 1, height: 1))
                    }
                }
                return ctx.makeImage()
            }
            var f: [String: CGImage] = [:]
            f["idle"] = image(fidget: false, eyesClosed: false, squash: false, z: nil)
            f["blink"] = image(fidget: false, eyesClosed: true, squash: false, z: nil)
            f["fidget"] = image(fidget: true, eyesClosed: false, squash: false, z: nil)
            for i in 0..<8 {
                f["sleep\(i)"] = image(fidget: false, eyesClosed: true, squash: i % 4 >= 2, z: i < 4 ? i : nil)
            }
            return f
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
