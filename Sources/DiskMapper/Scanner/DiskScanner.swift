import Darwin
import Foundation

// MARK: - Errors

public enum ScanError: Error, LocalizedError {
    case notADirectory(path: String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let p): return "Not a directory: \(p)"
        }
    }
}

// MARK: - Scanner

/// Recursively scans a directory tree and builds a `FileNode` tree.
///
/// ### I/O strategy
/// Each directory is read with `getattrlistbulk(2)` via `scanDirectoryEntries`,
/// which calls a closure per entry while the data is still in the pre-allocated
/// kernel buffer.  No intermediate `[BulkEntry]` array is created — `FileNode`
/// objects are built inline on the first (and only) pass through the buffer.
///
/// ### Buffer pool
/// A `SlotPool` pre-allocates `maxConcurrentDirectories` × 256 KB = 4 MB of
/// buffers once at scan start.  Each concurrent reader checks out one slot,
/// uses it for a single `scanDirectoryEntries` call, then returns it.
/// Zero buffer allocation/deallocation occurs during the scan itself.
///
/// ### Concurrency
/// Bounded to `maxConcurrentDirectories` simultaneous readers by the slot pool's
/// internal semaphore (same mechanism as the old DirSemaphore, now unified with
/// the buffer pool).
///
/// ### Volume boundaries
/// Detected via `st_dev` device ID captured once at scan start.
public struct DiskScanner: Sendable {

    public var maxConcurrentDirectories: Int
    public var crossVolumeBoundaries: Bool

    public init(
        maxConcurrentDirectories: Int = 16,
        crossVolumeBoundaries: Bool = false
    ) {
        self.maxConcurrentDirectories = maxConcurrentDirectories
        self.crossVolumeBoundaries    = crossVolumeBoundaries
    }

    /// Depth at which concurrency switches from TaskGroup to sequential awaits.
    /// Top 3 levels use concurrent I/O (where parallelism helps most); deeper
    /// directories are scanned sequentially to avoid creating ~50k Swift Tasks.
    private static let maxConcurrentDepth = 3

    /// Minimum depth before the small-subtree cutoff can fire.
    /// Prevents eliding shallow directories that may still have large children.
    private static let smallSubtreeCutoffDepth = 4

    /// If a directory at depth ≥ smallSubtreeCutoffDepth contains fewer than
    /// this many bytes of immediate files, its subdirectories are replaced with
    /// empty placeholder nodes rather than recursed into.  The current directory's
    /// own files are always scanned; only deeper descendants are elided.
    ///
    /// 1 MB: directories with <1 MB of immediate files are almost always small
    /// leaves — skipping their subtrees costs negligible accuracy.
    private static let smallSubtreeByteThreshold: Int64 = 1 * 1024 * 1024

    // MARK: - Hard-coded skip list

    private static let skipPaths: Set<String> = [
        "/dev",
        "/net",
        "/home",
        "/System/Volumes",
        "/private/var/vm",
        "/private/var/db/uuidtext",
        "/.vol",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.MobileBackups",
        "/private/var/db/dyld",
    ]

    private static func shouldSkip(_ path: String) -> Bool {
        if skipPaths.contains(path) { return true }
        if path.hasPrefix("/System/Volumes/") { return true }
        return false
    }

    // MARK: - Public API

    public func scan(url: URL, progress: ScanProgress) async throws -> FileNode {
        let rootValues = try url.resourceValues(
            forKeys: [.isDirectoryKey,
                      .volumeTotalCapacityKey,
                      .volumeAvailableCapacityKey]
        )
        guard rootValues.isDirectory == true else {
            throw ScanError.notADirectory(path: url.path)
        }

        if let total     = rootValues.volumeTotalCapacity,
           let available = rootValues.volumeAvailableCapacity,
           total > available {
            progress.setVolumeUsedBytes(Int64(total - available))
        }

        let rootDevID: dev_t? = crossVolumeBoundaries ? nil : deviceID(for: url.path)
        // Pre-allocate all I/O buffers once; they are reused for every directory read.
        let pool = SlotPool(capacity: maxConcurrentDirectories)

        let root = try await scanDirectory(
            path:         url.path,
            name:         url.lastPathComponent,
            absolutePath: url.path,
            rootDevID:    rootDevID,
            depth:        0,
            progress:     progress,
            pool:         pool
        )
        root.computeTotals()
        root.sortChildren()
        return root
    }

    // MARK: - Private

    private func scanDirectory(
        path:         String,
        name:         String,
        absolutePath: String?,       // non-nil only for the scan root
        rootDevID:    dev_t?,
        depth:        Int,
        progress:     ScanProgress,
        pool:         SlotPool
    ) async throws -> FileNode {

        if progress.isCancelled {
            return FileNode(name: name, isDirectory: true, allocatedSize: 0,
                            kind: .directory, absolutePath: absolutePath)
        }

        // Check out a slot (blocks until one is free), do the read, return it.
        let slot = await pool.acquire()

        var children:     [FileNode] = []
        var dirFileCount: Int        = 0
        var dirFileBytes: Int64      = 0
        // Subdirectory tasks accumulated during the inline scan closure.
        // Using a local array instead of spawning tasks inside the closure
        // keeps the closure simple and avoids capturing the task group.
        var pendingDirs: [(path: String, name: String)] = []

        // Parse the kernel buffer and build file nodes inline — no BulkEntry array.
        scanDirectoryEntries(path: path, slot: slot) { entryName, devid, isDir, isLink, allocSize, mdate in
            if isLink { return }

            let childPath = path == "/" ? "/\(entryName)" : "\(path)/\(entryName)"
            if Self.shouldSkip(childPath) { return }
            if let rootDev = rootDevID, devid != rootDev { return }

            if isDir {
                pendingDirs.append((path: childPath, name: entryName))
            } else {
                dirFileCount += 1
                dirFileBytes += allocSize
                let kind = FileKind.classify(pathExtension: pathExtension(of: entryName))
                children.append(FileNode(
                    name:         entryName,
                    isDirectory:  false,
                    allocatedSize: allocSize,
                    kind:         kind,
                    modifiedDate: mdate
                ))
            }
        }

        slot.release()  // return buffer to pool before spawning child tasks

        // Small-subtree cutoff: if we're deep enough and this directory's
        // immediate files are small, replace pending subdirectories with empty
        // placeholder nodes instead of recursing.  The directory appears in the
        // tree with its own files counted, but its subdirectories show as empty
        // dirs.  This avoids scanning thousands of tiny deep leaves (e.g. inside
        // .git/objects, node_modules) that collectively contain negligible data.
        if depth >= Self.smallSubtreeCutoffDepth,
           dirFileBytes < Self.smallSubtreeByteThreshold,
           !pendingDirs.isEmpty {
            for dir in pendingDirs {
                children.append(FileNode(
                    name:        dir.name,
                    isDirectory: true,
                    allocatedSize: 0,
                    kind:        .directory
                ))
            }
            progress.recordBatch(directoryName: name, fileCount: dirFileCount, bytes: dirFileBytes)
            let dirNode = FileNode(
                name:         name,
                isDirectory:  true,
                allocatedSize: 0,
                kind:         .directory,
                children:     children,
                absolutePath: absolutePath
            )
            for child in dirNode.children { child.parent = dirNode }
            return dirNode
        }

        // Recurse into subdirectories.
        // Shallow levels (depth < maxConcurrentDepth): TaskGroup for concurrent I/O.
        // Deep levels (depth >= maxConcurrentDepth): sequential awaits to avoid
        // creating thousands of Swift Tasks for leaves that rarely benefit from
        // parallelism.
        if depth < Self.maxConcurrentDepth {
            try await withThrowingTaskGroup(of: FileNode?.self) { group in
                for dir in pendingDirs {
                    let dirPath = dir.path
                    let dirName = dir.name
                    group.addTask {
                        try await self.scanDirectory(
                            path:         dirPath,
                            name:         dirName,
                            absolutePath: nil,
                            rootDevID:    rootDevID,
                            depth:        depth + 1,
                            progress:     progress,
                            pool:         pool
                        )
                    }
                }
                for try await child in group {
                    if let child { children.append(child) }
                }
            }
        } else {
            for dir in pendingDirs {
                let child = try await scanDirectory(
                    path:         dir.path,
                    name:         dir.name,
                    absolutePath: nil,
                    rootDevID:    rootDevID,
                    depth:        depth + 1,
                    progress:     progress,
                    pool:         pool
                )
                children.append(child)
            }
        }

        // One lock acquisition for the entire directory's file stats.
        progress.recordBatch(directoryName: name, fileCount: dirFileCount, bytes: dirFileBytes)

        let dirNode = FileNode(
            name:         name,
            isDirectory:  true,
            allocatedSize: 0,
            kind:         .directory,
            children:     children,
            absolutePath: absolutePath
        )
        for child in dirNode.children { child.parent = dirNode }
        return dirNode
    }
}

// MARK: - Helpers

private func deviceID(for path: String) -> dev_t? {
    var st = stat()
    guard path.withCString({ stat($0, &st) }) == 0 else { return nil }
    return st.st_dev
}

private func pathExtension(of name: String) -> String {
    guard let dotIdx = name.lastIndex(of: "."),
          dotIdx != name.startIndex else { return "" }
    return String(name[name.index(after: dotIdx)...])
}
