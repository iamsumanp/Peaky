import AppKit
import CoreText
import SwiftUI

/// The "Pixel" look: pure black, small corners, amber accent, segmented bars.
///
/// Fonts: Pixelify Sans (titles), Geist (body), Geist Mono (numbers, times). They are not bundled —
/// drop the .ttf files into Peaky/Fonts and rebuild, and they are picked up automatically. Until then
/// titles fall back to SF Pro Rounded, body to SF Pro and numbers to SF Mono.
enum Theme {
    // MARK: Colour

    /// CSS-style oklch(L C H / alpha) → sRGB.
    static func oklch(_ l: Double, _ c: Double, _ hDeg: Double, _ alpha: Double = 1) -> Color {
        let h = hDeg * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        // OKLab → LMS (cube) → linear sRGB
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func gamma(_ x: Double) -> Double {
            let v = max(0, min(1, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(bl), opacity: alpha)
    }

    /// UI accent (amber).
    static let accent = oklch(0.80, 0.15, 60)
    /// Battery and AirPods levels.
    static let level = oklch(0.80, 0.16, 150)
    /// Empty blocks of a segmented bar.
    static let empty = Color.white.opacity(0.14)

    // MARK: Shape

    /// Tiles and buttons.
    static let tileRadius: CGFloat = 4
    static let compactBottomRadius: CGFloat = 8
    static let expandedBottomRadius: CGFloat = 14

    // MARK: Fonts

    private static func has(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }
    private static let hasPixelify = has("Pixelify Sans")
    private static let hasGeist = has("Geist")
    private static let hasGeistMono = has("Geist Mono")

    static func title(_ size: CGFloat) -> Font {
        hasPixelify ? .custom("Pixelify Sans", size: size).weight(.semibold)
                    : .system(size: size, weight: .bold, design: .rounded)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasGeist ? .custom("Geist", size: size).weight(weight) : .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        hasGeistMono ? .custom("Geist Mono", size: size).weight(weight)
                     : .system(size: size, weight: weight, design: .monospaced)
    }

    /// AppKit versions, for measuring text (notice widths).
    static func nsTitle(_ size: CGFloat) -> NSFont {
        if hasPixelify, let f = NSFontManager.shared.font(withFamily: "Pixelify Sans", traits: [], weight: 8, size: size) { return f }
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    static func nsBody(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        if hasGeist, let f = NSFontManager.shared.font(withFamily: "Geist", traits: [], weight: 6, size: size) { return f }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Registers any fonts shipped in Peaky.app/Contents/Resources/Fonts (process-local, not system-wide).
    static func registerBundledFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

/// A segmented progress bar: 1pt-radius blocks with a 2pt gap, 6pt tall.
struct SegmentedBar: View {
    let value: Double          // 0…1
    var fill: Color = Theme.accent
    var block: CGFloat = 4
    var height: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 2
            let n = max(1, Int((size.width + gap) / (block + gap)))
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let filled = Int((Double(n) * min(1, max(0, value))).rounded())
            for i in 0..<n {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - height) / 2, width: w, height: height)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(i < filled ? fill : Theme.empty))
            }
        }
        .frame(height: height)
    }
}
