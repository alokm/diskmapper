import Foundation

/// Broad category for a file, used to assign colors in the treemap.
public enum FileKind: String, CaseIterable, Sendable {
    case directory
    case image
    case video
    case audio
    case document
    case archive
    case code
    case executable
    case other

    /// Classifies a file by its path extension.
    public static func classify(pathExtension: String) -> FileKind {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "ico", "raw", "cr2", "nef", "arw":
            return .image
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mts", "m2ts":
            return .video
        case "mp3", "aac", "wav", "flac", "m4a", "ogg", "opus", "aiff", "alac", "wma":
            return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key", "odt", "ods", "odp", "epub":
            return .document
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "tgz", "tbz2", "zst":
            return .archive
        case "swift", "py", "js", "ts", "jsx", "tsx", "rb", "go", "rs", "java", "kt", "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "json", "xml", "yaml", "yml", "toml", "html", "css", "scss", "less", "sql":
            return .code
        case "app", "dylib", "so", "o", "a", "framework", "xcframework":
            return .executable
        default:
            return .other
        }
    }
}
