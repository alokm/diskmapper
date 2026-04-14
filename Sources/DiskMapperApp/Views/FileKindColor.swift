import SwiftUI
import DiskMapper

// MARK: - Color theme

/// Controls how cells in the treemap are coloured.
enum ColorTheme: String, CaseIterable, Identifiable {
    case byKind     = "By Kind"
    case bySize     = "By Size"
    case monochrome = "Mono"
    var id: String { rawValue }
}

// MARK: -

/// Maps `FileKind` values to display colors and legend metadata.
struct FileKindColor {

    // MARK: - By Kind palette
    //
    // Vivid, distinct colors inspired by ColorBrewer Set1 + macOS accent palette.
    // High saturation (0.75–0.90) and brightness (0.88–1.00) so cells pop against
    // the dark background even at small sizes.

    static func color(for kind: FileKind) -> Color {
        switch kind {
        case .directory:  return Color(hue: 0.130, saturation: 0.80, brightness: 1.00)  // golden yellow
        case .image:      return Color(hue: 0.370, saturation: 0.82, brightness: 0.92)  // vivid green
        case .video:      return Color(hue: 0.590, saturation: 0.88, brightness: 1.00)  // electric blue
        case .audio:      return Color(hue: 0.520, saturation: 0.78, brightness: 0.95)  // cyan-teal
        case .document:   return Color(hue: 0.085, saturation: 0.85, brightness: 1.00)  // bright orange
        case .archive:    return Color(hue: 0.790, saturation: 0.75, brightness: 0.98)  // vivid violet
        case .code:       return Color(hue: 0.020, saturation: 0.88, brightness: 1.00)  // hot red-orange
        case .executable: return Color(hue: 0.950, saturation: 0.80, brightness: 0.92)  // magenta-pink
        case .other:      return Color(hue: 0.000, saturation: 0.00, brightness: 0.55)  // neutral grey
        }
    }

    // MARK: - By Size gradient (OKLCH-inspired smooth ramp)
    //
    // Interpolates through a hand-picked 5-stop ramp in perceptual order:
    //   deep indigo → cobalt blue → teal → lime → amber → hot coral
    // Stops are in sRGB but chosen to be perceptually equidistant in lightness,
    // avoiding the "bright yellow spike" of plain HSB gradients.

    private static let sizeGradientStops: [(t: Double, r: Double, g: Double, b: Double)] = [
        (0.00, 0.10, 0.12, 0.55),   // deep indigo
        (0.25, 0.07, 0.45, 0.82),   // cobalt blue
        (0.50, 0.05, 0.72, 0.72),   // teal
        (0.75, 0.55, 0.82, 0.10),   // lime-yellow
        (1.00, 1.00, 0.38, 0.12),   // hot coral
    ]

    static func sizeGradientColor(ratio: Double) -> Color {
        let t = max(0, min(1, ratio))
        let stops = sizeGradientStops

        // Find the two bracketing stops and lerp between them.
        for i in 1..<stops.count {
            let lo = stops[i - 1]
            let hi = stops[i]
            if t <= hi.t {
                let span = hi.t - lo.t
                let f = span > 0 ? (t - lo.t) / span : 0
                return Color(
                    red:   lo.r + (hi.r - lo.r) * f,
                    green: lo.g + (hi.g - lo.g) * f,
                    blue:  lo.b + (hi.b - lo.b) * f
                )
            }
        }
        let last = stops.last!
        return Color(red: last.r, green: last.g, blue: last.b)
    }

    // MARK: - Themed color

    /// Returns a colour for `kind` according to `theme`.
    ///
    /// - Parameter sizeRatio: The node's `totalSize` divided by the root's
    ///   `totalSize` (0…1). Only used by `.bySize` and `.monochrome` themes.
    static func color(for kind: FileKind, theme: ColorTheme, sizeRatio: Double = 0) -> Color {
        switch theme {
        case .byKind:
            return color(for: kind)
        case .bySize:
            // Log-scale so small and large files both get useful colours.
            let clamped = max(0, min(1, sizeRatio))
            let logRatio = clamped < 1e-9 ? 0.0 : log10(clamped * 9 + 1)   // log10(1..10) → 0..1
            return sizeGradientColor(ratio: logRatio)
        case .monochrome:
            let clamped = max(0, min(1, sizeRatio))
            // Perceptually linear: gamma-correct the brightness ramp.
            let brightness = 0.18 + pow(clamped, 0.55) * 0.70
            return Color(white: brightness)
        }
    }

    // MARK: - Cell gradient overlay
    //
    // A subtle top-to-bottom brightness gradient drawn over each filled cell
    // to add depth and make adjacent same-colour cells easier to distinguish.

    static func gradientColors(base: Color) -> (top: Color, bottom: Color) {
        return (
            top:    base.opacity(0.72),   // slightly transparent at top
            bottom: base                   // full colour at bottom
        )
    }

    // MARK: - Icons

    static func iconName(for kind: FileKind) -> String {
        switch kind {
        case .directory:  return "folder.fill"
        case .image:      return "photo.fill"
        case .video:      return "film.fill"
        case .audio:      return "music.note"
        case .document:   return "doc.fill"
        case .archive:    return "archivebox.fill"
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .executable: return "gearshape.fill"
        case .other:      return "doc"
        }
    }

    // MARK: - Legend

    static let legend: [(kind: FileKind, label: String)] = [
        (.image,      "Images"),
        (.video,      "Video"),
        (.audio,      "Audio"),
        (.document,   "Documents"),
        (.archive,    "Archives"),
        (.code,       "Code"),
        (.executable, "Executables"),
        (.other,      "Other"),
    ]
}
