import Foundation

/// A node in the scanned filesystem tree, representing either a file or directory.
///
/// ### Path storage
/// Full path strings are NOT stored per node (unlike the previous implementation).
/// Only the leaf `name` is stored.  The `path` property is computed on demand by
/// walking up the `parent` chain — O(depth), which is effectively O(1) for typical
/// directory trees (~20 levels deep).  This eliminates ~40 MB of heap allocations
/// on a 500k-file drive scan.
///
/// The scan root node is the only exception: it stores its absolute path in
/// `_absolutePath` so the chain can be anchored.
///
/// ### Thread safety
/// `@unchecked Sendable` is safe because:
/// - `parent` is set once during tree assembly (before the tree is shared)
/// - all other mutations (`totalSize`, `children`) happen in the construction phase
///   before the tree is handed to the UI
public final class FileNode: Identifiable, @unchecked Sendable {

    // MARK: - Identity

    /// Unique identifier — the full filesystem path (computed on demand).
    public var id: String { path }

    // MARK: - Name & path

    public let name: String

    /// Absolute path — computed by walking up the parent chain.
    /// O(depth); cached by callers if needed for tight loops.
    public var path: String {
        // Root node: stored directly.
        if let abs = _absolutePath { return abs }
        // All other nodes: concatenate parent path + name.
        guard let p = parent else { return name }
        let pp = p.path
        return pp == "/" ? "/\(name)" : "\(pp)/\(name)"
    }

    // Non-nil only for the scan root (where parent == nil).
    private let _absolutePath: String?

    /// Weak back-pointer to the parent directory node.
    /// `nil` for the scan root.  Set by `DiskScanner` after the parent node
    /// is created — not passed through `init` because parents are created
    /// after their children during tree assembly.
    public internal(set) weak var parent: FileNode?

    // MARK: - Attributes

    public let isDirectory: Bool
    public let kind: FileKind
    /// Content modification date fetched from the filesystem during scanning.
    public let modifiedDate: Date?

    // MARK: - Size

    /// For files: bytes allocated on disk (block-aligned).
    /// For directories: 0 until `computeTotals()` is called on an ancestor.
    public private(set) var totalSize: Int64

    // MARK: - Tree

    /// Ordered children (directories first, then files, both sorted largest-first
    /// after `sortChildren()` is called).
    public internal(set) var children: [FileNode]

    // MARK: - Init

    init(
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        kind: FileKind,
        modifiedDate: Date? = nil,
        children: [FileNode] = [],
        absolutePath: String? = nil   // only set for the scan root node
    ) {
        self.name          = name
        self._absolutePath = absolutePath
        self.isDirectory   = isDirectory
        self.kind          = kind
        self.modifiedDate  = modifiedDate
        self.children      = children
        self.totalSize     = isDirectory ? 0 : allocatedSize
    }

    // MARK: - Post-build passes

    /// Recursively computes and caches `totalSize` for all directory nodes (bottom-up).
    /// Call once on the root after the full tree has been built.
    public func computeTotals() {
        guard isDirectory else { return }
        for child in children {
            child.computeTotals()
        }
        totalSize = children.reduce(0) { $0 + $1.totalSize }
    }

    /// Recursively sorts children by `totalSize` descending (largest first).
    public func sortChildren() {
        children.sort { $0.totalSize > $1.totalSize }
        for child in children where child.isDirectory {
            child.sortChildren()
        }
    }
}

// MARK: - Debug

extension FileNode: CustomStringConvertible {
    public var description: String {
        "\(isDirectory ? "Dir" : "File")(\(name), \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)))"
    }
}
