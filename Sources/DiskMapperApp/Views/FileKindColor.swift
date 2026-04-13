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

    // MARK: - Color palette

    static func color(for kind: FileKind) -> Color {
        switch kind {
        case .directory:  return Color(hue: 0.12, saturation: 0.55, brightness: 0.95)  // macOS folder yellow
        case .image:      return Color(hue: 0.33, saturation: 0.65, brightness: 0.72)  // green
        case .video:      return Color(hue: 0.62, saturation: 0.70, brightness: 0.80)  // blue
        case .audio:      return Color(hue: 0.50, saturation: 0.60, brightness: 0.72)  // teal
        case .document:   return Color(hue: 0.11, saturation: 0.72, brightness: 0.85)  // amber
        case .archive:    return Color(hue: 0.77, saturation: 0.55, brightness: 0.75)  // purple
        case .code:       return Color(hue: 0.03, saturation: 0.68, brightness: 0.78)  // red-orange
        case .executable: return Color(hue: 0.96, saturation: 0.65, brightness: 0.62)  // crimson
        case .other:      return Color(hue: 0.00, saturation: 0.00, brightness: 0.52)  // mid-grey
        }
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
            // Use a log-scale ratio so small and large files both get useful colours.
            // Maps 0 → cool blue (hue 0.65), 1 → warm red (hue 0.0).
            let clamped = max(0, min(1, sizeRatio))
            let hue = 0.65 * (1.0 - clamped)
            return Color(hue: hue, saturation: 0.72, brightness: 0.82)
        case .monochrome:
            let clamped = max(0, min(1, sizeRatio))
            return Color(white: 0.22 + clamped * 0.55)
        }
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
