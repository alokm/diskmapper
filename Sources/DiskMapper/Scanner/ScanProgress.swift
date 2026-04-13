import Foundation
import os

/// Thread-safe progress state for an in-flight disk scan.
///
/// ### Design
/// The previous implementation was a Swift `actor`.  Every `recordFile` and
/// `recordDirectory` call from the scanner required an `await` to cross the
/// actor isolation boundary — roughly 100–300 ns of scheduling overhead per
/// call, totalling 50–150 ms of pure scheduler tax on a 500k-file drive, plus
/// the overhead of creating and scheduling a suspension point for every file.
///
/// This version replaces the actor with an `OSAllocatedUnfairLock` (available
/// macOS 13+).  Lock/unlock on an uncontended `os_unfair_lock` costs ~5–10 ns
/// and does **not** create a suspension point — `recordFile` and
/// `recordDirectory` return synchronously.  Callers no longer need `await`.
///
/// The UI poller (`AppState.progressTask`) calls `snapshot()` once per 150 ms
/// tick to read all fields in a single lock acquisition instead of making three
/// separate actor round-trips.
///
/// ### Thread safety
/// All mutable fields are protected by `_lock`.  `isCancelled` is accessed
/// with the lock held on write and on read from the scanner hot path
/// (`checkCancelled()`); the UI poller reads it via `snapshot()`.
public final class ScanProgress: @unchecked Sendable {

    // MARK: - Snapshot (returned to the UI poller)

    /// Immutable point-in-time view of all progress fields.
    /// Captured in a single lock acquisition — cheaper than reading fields
    /// individually across multiple async calls.
    public struct Snapshot {
        public let scannedFiles: Int
        public let scannedDirectories: Int
        public let scannedBytes: Int64
        public let volumeUsedBytes: Int64
        public let currentName: String
        public let isCancelled: Bool

        public var totalScanned: Int { scannedFiles + scannedDirectories }

        /// 0…1 fraction of the volume's used bytes accounted for so far.
        /// `nil` when the volume size is unknown (subdirectory scan).
        public var progressFraction: Double? {
            guard volumeUsedBytes > 0 else { return nil }
            return min(1.0, Double(scannedBytes) / Double(volumeUsedBytes))
        }
    }

    // MARK: - Mutable state (protected by _lock)

    private let _lock = OSAllocatedUnfairLock(initialState: _State())

    private struct _State {
        var scannedFiles: Int      = 0
        var scannedDirectories: Int = 0
        var scannedBytes: Int64    = 0
        var volumeUsedBytes: Int64 = 0
        var currentName: String    = ""
        var errors: [String]       = []
        var isCancelled: Bool      = false
    }

    // MARK: - Init

    public init() {}

    // MARK: - Mutations (called synchronously by DiskScanner — no await needed)

    public func setVolumeUsedBytes(_ bytes: Int64) {
        _lock.withLock { $0.volumeUsedBytes = bytes }
    }

    /// Records all files in a single directory in one lock acquisition.
    ///
    /// Called once per directory instead of once per file — reduces lock
    /// acquisitions from ~500k to ~50k on a typical 500k-file drive scan.
    ///
    /// - Parameters:
    ///   - directoryName: Leaf name of the directory just scanned (displayed in UI).
    ///   - fileCount:     Number of regular files in this directory (not recursive).
    ///   - bytes:         Sum of allocated sizes of those files.
    public func recordBatch(directoryName: String, fileCount: Int, bytes: Int64) {
        _lock.withLock {
            $0.scannedDirectories += 1
            $0.scannedFiles       += fileCount
            $0.scannedBytes       += bytes
            $0.currentName         = directoryName
        }
    }

    public func recordError(path: String) {
        _lock.withLock { $0.errors.append(path) }
    }

    // MARK: - Cancellation

    public func cancel() {
        _lock.withLock { $0.isCancelled = true }
    }

    /// Fast synchronous cancellation check — no `await` needed.
    public var isCancelled: Bool {
        _lock.withLock { $0.isCancelled }
    }

    // MARK: - Individual field accessors (for tests and direct reads)

    public var scannedFiles: Int        { _lock.withLock { $0.scannedFiles } }
    public var scannedDirectories: Int  { _lock.withLock { $0.scannedDirectories } }

    // MARK: - UI read path

    /// Returns a point-in-time snapshot of all fields in a single lock
    /// acquisition.  Call this from the progress-polling task instead of
    /// reading individual properties.
    public func snapshot() -> Snapshot {
        _lock.withLock {
            Snapshot(
                scannedFiles:      $0.scannedFiles,
                scannedDirectories: $0.scannedDirectories,
                scannedBytes:      $0.scannedBytes,
                volumeUsedBytes:   $0.volumeUsedBytes,
                currentName:       $0.currentName,
                isCancelled:       $0.isCancelled
            )
        }
    }
}
