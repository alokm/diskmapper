import AppKit
import DiskMapper

/// Thin wrappers around `NSWorkspace` and `FileManager` for common file operations.
enum FinderActions {

    /// Opens a Finder window with the item selected.
    static func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: node.path)]
        )
    }

    /// Writes the item's full path to the system clipboard.
    static func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    /// Moves the item to the Trash. Returns `true` on success.
    @discardableResult
    static func moveToTrash(_ node: FileNode) -> Bool {
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: node.path),
                resultingItemURL: nil
            )
            return true
        } catch {
            return false
        }
    }
}
