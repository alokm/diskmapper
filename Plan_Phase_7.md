# Plan_Phase_7 — Stability, Sort by Date & Real Scan Progress

## Overview

Three improvements made after Phase 6:

1. **Sort by date** — third sort option in the sidebar header
2. **Scanner stability** — bounded concurrency + macOS virtual-path skip list to fix hangs on large drives
3. **Determinate scan progress** — linear progress bar, percentage readout, and rolling items/sec rate

---

## 1. Sort by Date

### `Sources/DiskMapperApp/Views/NavigatorSidebar.swift`

- Added `.date` case to the private `SidebarSort` enum
- Added sort branch in `sortedChildren`: most recently modified first; nodes with no `modifiedDate` sort to the bottom
- Added a `calendar` icon segment to the `Picker` (width widened from 54 → 80 pt)
- Tooltip updated to "Sort by size / name / date modified"

---

## 2. Scanner Stability

### Problem

Scanning `/` (the whole drive) would stall after ~50k files for **three** reasons:

1. **Unbounded concurrency** — `withThrowingTaskGroup` spawned one concurrent task per child file/directory with no cap. On a 500k-file drive this meant hundreds of thousands of in-flight I/O tasks competing for threads, causing thread-pool starvation.

2. **`/Volumes` not in skip list** — the scanner entered `/Volumes` and attempted to list mounted network shares, Time Machine disks, and external drives. Any such volume can hang `contentsOfDirectory` **indefinitely** with no timeout.

3. **Semaphore deadlock** — once blocking I/O consumed all 16 semaphore slots waiting on a hung volume, the entire scan froze. No new tasks could acquire a slot; no stuck tasks could return to release theirs.

4. **macOS virtual paths** — hard-coded skip list for pseudo-filesystems and AutoFS:
   | Path | Issue |
   |------|-------|
   | `/dev` | Character/block device files; reads block indefinitely |
   | `/net`, `/home` | macOS AutoFS; triggers a network mount on first `stat` |
   | `/System/Volumes` | APFS firmlinks that mirror `/Users`, `/Applications`, `/Library` — double-counts entire data volume |
   | `/private/var/vm` | Swap files; very large and slow to stat |
   | `/private/var/db/uuidtext` | Millions of tiny UUID-named files; listing alone takes minutes |
   | `/.vol`, `/.Spotlight-V100`, `/.fseventsd`, `/.MobileBackups`, `/private/var/db/dyld` | Various macOS internals |

### `Sources/DiskMapper/Scanner/DiskScanner.swift` (rewritten)

**Concurrency & locking:**
- Added `DirSemaphore` — a private `actor`-based counting semaphore
  - `limit` defaults to 16 concurrent `contentsOfDirectory` calls
  - `acquire()` / `release()` suspend/resume waiting tasks via `CheckedContinuation`
- Semaphore slot is acquired immediately before `contentsOfDirectory` and **released immediately after** the call returns — not held while child tasks run. This prevents deadlock even if a single call hangs.

**Volume-boundary detection (primary hang fix):**
- Added `public var crossVolumeBoundaries: Bool` (default `false`)
- At scan start, reads the root URL's `.volumeURLKey` via `allValues[.volumeURLKey] as? URL`
- In `scanItem`, any entry whose `volumeURL` differs from the root is silently skipped
- This prevents entry into `/Volumes/NetworkShare`, Time Machine disks, and any other mounted volume automatically — no hard-coded list needed
- User can set `crossVolumeBoundaries: true` to scan only a specific external drive when explicitly requested

**Hard skip list:**
- Expanded `skipPaths` set with additional macOS internals: `/.vol`, `/.Spotlight-V100`, `/.fseventsd`, `/.MobileBackups`, `/private/var/db/dyld`
- `shouldSkip(_ path:)` is checked before any filesystem call

**Other:**
- `scan(url:progress:)` fetches `.volumeTotalCapacityKey` and `.volumeAvailableCapacityKey` to enable determinate progress
- `scanItem` passes `allocatedSize:` to `progress.recordFile`

---

## 3. Determinate Scan Progress

### `Sources/DiskMapper/Scanner/ScanProgress.swift`

- Added `public private(set) var scannedBytes: Int64 = 0` — accumulated as each file is recorded
- Added `public private(set) var volumeUsedBytes: Int64 = 0` — set once at scan start
- Added `func setVolumeUsedBytes(_ bytes: Int64)`
- `recordFile(path:)` → `recordFile(path:allocatedSize:)` — increments `scannedBytes`
- Added computed `progressFraction: Double?`:
  - `nil` when `volumeUsedBytes == 0` (subdirectory scan, volume size unknown)
  - `min(1.0, Double(scannedBytes) / Double(volumeUsedBytes))` otherwise

### `Sources/DiskMapperApp/AppState.swift`

- Added `@Published var scanProgress: Double? = nil`
- Added `@Published var itemsPerSecond: Double = 0`
- Progress polling loop now:
  - Reads `progress.progressFraction` → publishes as `scanProgress`
  - Computes instantaneous items/sec from count delta over the 150 ms interval
  - Applies exponential-moving-average smoothing (α = 0.3) for a stable display rate
- Both values reset to `nil` / `0` at the start of each new scan

### `Sources/DiskMapperApp/ContentView.swift`

- **Toolbar scanning section**: linear `ProgressView(value: fraction)` (80 pt wide) when `scanProgress != nil`; falls back to indeterminate spinner otherwise
- **`progressLabel`**: appends `"  ·  8,312/s"` when `itemsPerSecond > 0`
- **`scanningPlaceholder`** (full-screen): shows the progress bar (280 pt) + large thin `"42%"` percentage label when fraction is known; falls back to spinner for subdirectory scans

---

## Build Status

`swift build` → **Build complete** (no errors).
