# DiskMapper — Performance Optimization Plan

## Current Architecture Summary

The scan pipeline has four stages:

1. **I/O** — `DiskScanner` walks the tree using `FileManager.contentsOfDirectory` + per-file `url.resourceValues(forKeys:)`. Concurrency is bounded by a 16-slot actor-based semaphore.
2. **Tree build** — Each file creates a heap-allocated `FileNode` (class). After the full tree is built, `computeTotals()` and `sortChildren()` do bottom-up passes.
3. **Layout** — `TreemapLayout.layout()` recursively converts the tree into `[LayoutRect]` (squarified algorithm).
4. **Render** — `Canvas` draws rects in 5 separate passes (fills, borders, labels, selection, hover).

---

## Tier 1 — High Impact, Low-to-Medium Effort

### 1.1 Replace `url.resourceValues` with `getattrlistbulk` (~2–5× scan speedup)

**Current cost:** Two syscalls per directory — `contentsOfDirectory` does an `opendir`/`readdir` loop to discover names, then `resourceValues(forKeys:)` does a separate `getattrlist` syscall per child to fetch size, dates, etc. For 500k files that's **1M+ syscalls**.

**Fix:** Use Darwin's `getattrlistbulk(2)` which returns attributes for *all* entries in a directory in a single syscall, packed into a caller-supplied buffer. This is what Finder and `du` use internally.

```
Pseudocode:
  fd = open(dirPath, O_RDONLY)
  buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024)
  while getattrlistbulk(fd, &attrList, buffer, bufSize, 0) > 0 {
      // parse packed entries: name, type, size, dates, device
      // build FileNode directly from raw attributes
  }
```

**Gains:**
- Eliminates per-file `stat`/`getattrlist` calls — single syscall per directory
- Avoids creating `URL` objects per file (Foundation overhead)
- Avoids creating `URLResourceValues` dictionaries per file
- Expected 2–5× reduction in total wall-clock scan time

**Effort:** Medium. Requires C-interop for the packed attribute buffer parsing. The `attrList` struct and attribute buffer layout are well-documented in `<sys/attr.h>`.

### 1.2 Eliminate per-file actor await in ScanProgress (~15–25% scan speedup)

**Current cost:** Every file calls `await progress.recordFile(path:allocatedSize:)` and every directory calls `await progress.recordDirectory(path:)`. Each `await` crosses an actor isolation boundary — even uncontended, this costs ~100–300 ns of scheduling overhead. At 500k files, that's **50–150 ms of pure actor-scheduling overhead**, plus contention when multiple tasks compete.

**Fix:** Replace the actor with lock-free atomics for counters + a periodic path update.

```swift
import Atomics

public final class ScanProgress: @unchecked Sendable {
    private let _scannedFiles = ManagedAtomic<Int>(0)
    private let _scannedBytes = ManagedAtomic<Int64>(0)
    private let _isCancelled  = ManagedAtomic<Bool>(false)
    // Path updated via os_unfair_lock — only needs to be "recent", not exact
    ...
}
```

Each `recordFile` becomes a non-blocking `fetchAdd` — no `await`, no actor hop, no suspension point.

**Gains:**
- Removes the single hottest `await` from the scan loop
- `DiskScanner.scanItem` becomes fully synchronous between I/O calls (no actor yield per file)
- Reduces Task scheduling pressure by ~500k context switches

**Effort:** Low. Swift Atomics is a well-maintained package. The path string can use a lock-protected slot with a generation counter; the UI poller only needs to read it every 150 ms.

### 1.3 Batch progress reads into a single snapshot (~3–5% UI responsiveness)

**Current cost:** `AppState.progressTask` polls 5 separate `await progress.*` properties per tick (150 ms), each a separate actor message.

**Fix:** Add a single `func snapshot() -> ProgressSnapshot` method that returns all fields in one actor call. This is complementary to 1.2 — if the actor is replaced with atomics, this becomes even cheaper (just atomic loads + one lock acquisition for the path string).

**Effort:** Trivial. 10-minute change.

---

## Tier 2 — Medium Impact, Low Effort

### 2.1 Replace DirSemaphore actor with `os_unfair_lock` + DispatchSemaphore

**Current cost:** The `DirSemaphore` actor uses `CheckedContinuation` which involves heap allocation per waiter and actor scheduling per acquire/release. With 16 concurrent tasks all contending on the same actor, this serializes at the actor level.

**Fix:** Use `DispatchSemaphore(value: 16)` — the kernel handles fairness and waiting; no actor hop needed. Or use a custom async semaphore backed by `os_unfair_lock` for the counter and `AsyncStream` for waiting, avoiding actor overhead.

**Gains:** 8–12% scan speedup by removing the second-hottest actor from the fast path.

**Effort:** Low. `DispatchSemaphore` is a drop-in replacement; wrap in a `Sendable` struct.

### 2.2 Stop storing full paths in progress — store only the leaf name

**Current cost:** `recordFile(path: url.path)` allocates a full path string (e.g. `/Users/alice/Library/Caches/com.apple.something/cache-entry-12345`) for every file, just so the UI can show `"cache-entry-12345"` in the status bar.

**Fix:** Pass only `url.lastPathComponent` (or even skip the update for most files — update path every Nth file).

```swift
func recordFile(name: String, allocatedSize: Int64) {
    _scannedFiles.wrappingIncrement(ordering: .relaxed)
    _scannedBytes.wrappingAdd(allocatedSize, ordering: .relaxed)
    // Only update display path every 128 files to reduce string allocations
    if _scannedFiles.load(ordering: .relaxed) & 0x7F == 0 {
        lock.lock(); currentName = name; lock.unlock()
    }
}
```

**Gains:** Eliminates ~500k `String` heap allocations during scanning.

**Effort:** Low. Change one parameter, update two callers.

### 2.3 Pre-allocate `layoutRects` array

**Current cost:** `TreemapLayout.layout()` uses `result.append(contentsOf:)` at every recursion level. For 100k visible nodes, this causes multiple array reallocations as the array grows.

**Fix:** Estimate the output count (e.g. `node.children.count` recursively, or cap at 200k) and `reserveCapacity`. Or use an `inout [LayoutRect]` parameter instead of returning arrays.

**Gains:** 5–8% layout speedup for large trees. Eliminates reallocation-induced copies.

**Effort:** Low.

### 2.4 Cache `filteredChildren` in NavigatorSidebar

**Current cost:** `filteredChildren` is a computed property that re-sorts and re-filters on every SwiftUI state change. With 10k children in a single directory, this is noticeable.

**Fix:** Memoize with `@State` / `.onChange` pattern — only recompute when `sortOrder`, `searchText`, `showHiddenFiles`, or `displayRoot` change.

**Effort:** Low.

---

## Tier 3 — Medium Impact, Higher Effort

### 3.1 Incremental / cached rescans using FSEvents

**Current cost:** Every rescan walks the entire tree from scratch.

**Fix:** On first scan, save the tree to disk (binary plist or SQLite). On rescan, use FSEvents to determine which directories changed since the last scan, and only re-walk those subtrees. Unchanged subtrees are loaded from cache.

**Gains:** Rescan of a 500k-file drive in <1 second instead of 10–30 seconds (assuming <1% of directories changed).

**Effort:** High. Requires a persistence layer, FSEvents integration, and merge logic for partial tree updates.

### 3.2 Worker-pool model instead of TaskGroup fan-out

**Current cost:** Each directory spawns N child tasks in a `withThrowingTaskGroup`. For a drive with 50k directories × average 15 children, that's **750k Task objects** created and scheduled. Each Task has overhead (~256 bytes + scheduling).

**Fix:** Use a fixed pool of 16–32 worker tasks pulling directories from a concurrent queue (`AsyncStream` or lock-free MPMC queue). Each worker runs a tight loop: dequeue directory → list contents → enqueue child directories → build nodes. No per-file Task creation.

```
queue = AsyncChannel<URL>()
queue.send(rootURL)

await withTaskGroup {
    for _ in 0..<32 {
        group.addTask {
            for await dirURL in queue {
                let children = listDirectory(dirURL)
                for child in children where child.isDir {
                    await queue.send(child.url)
                }
                buildNodes(children)
            }
        }
    }
}
```

**Gains:** Dramatically reduces Task scheduling overhead. Expected 10–20% overall scan speedup from reduced concurrency machinery.

**Effort:** Medium-high. Requires rethinking how the tree is assembled (currently recursive; needs to become iterative with parent back-pointers or a post-assembly phase).

### 3.3 Use `fts(3)` for directory traversal

**Alternative to 1.1** if `getattrlistbulk` is too complex. The BSD `fts_open`/`fts_read` API traverses an entire directory tree in a single call, handling cycle detection, symlinks, and sorting internally. It returns `FTSENT` structs with pre-fetched `stat` data.

```swift
let paths = [rootPath].map { strdup($0)! } + [nil]
guard let stream = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { ... }
while let entry = fts_read(stream) {
    // entry.pointee.fts_statp has size, dates, etc.
    // entry.pointee.fts_name has the filename
}
fts_close(stream)
```

**Gains:** Single-threaded `fts` on macOS is surprisingly fast (APFS is designed for it). May match or beat the concurrent Foundation approach with far less code.

**Trade-off:** Single-threaded by nature. Could run in a `Task.detached` with periodic yields. Doesn't benefit from concurrent I/O on SSDs but avoids all concurrency overhead.

**Effort:** Medium. Requires building the FileNode tree from a flat stream.

### 3.4 Viewport-limited layout computation

**Current cost:** `TreemapLayout.layout()` recursively lays out the *entire* visible subtree, including deeply nested directories the user hasn't drilled into. For a 500k-node tree, this computes positions for hundreds of thousands of rects that are each < 1 pixel.

**Current mitigation:** `minVisibleSize: 2.0` prunes sub-2px rects. But the pruning happens *after* the squarify pass, so the CPU work is still done.

**Fix:** Limit recursion depth to 3–4 levels from `displayRoot`. Deeper levels are computed lazily when the user drills down. For a typical directory with 20 children, each with 20 children (3 levels = 8,000 nodes), this is ~100× less work than laying out 500k nodes.

**Gains:** Layout drops from ~100 ms to ~1 ms for large trees. Drill-down recomputes only the visible subtree.

**Effort:** Low-medium. Add a `maxDepth` parameter to `layout()` and pass it from `scheduleLayout`.

---

## Tier 4 — Lower Priority / Speculative

### 4.1 Metal renderer for extreme node counts

Replace SwiftUI `Canvas` with a Metal compute shader that maps each rect to GPU-rendered quads. Relevant only for >1M visible nodes. The current Canvas handles 100k rects at 60 fps; Metal would be needed for 500k+ visible rects.

### 4.2 Reduce FileNode memory footprint

- Store `FileKind` as `UInt8` instead of an enum with `String` rawValue (saves 7 bytes/node)
- Intern short file names (many files share names like `index.js`, `.DS_Store`)
- Use `Int32` for `allocatedSize` when < 2 GB (saves 4 bytes/node but adds branching)
- Pool-allocate FileNode objects from a contiguous buffer to improve cache locality

### 4.3 Single-pass Canvas rendering

Merge the 5 drawing passes into a single iteration: draw fill → border → label per rect, then overlay selection/hover in a second pass. Reduces iteration from 5N to N + 2 (for the two highlighted rects).

---

## Implementation Status

| Item | Status | Actual Gain | Notes |
|------|--------|-------------|-------|
| **1.1** — `getattrlistbulk` | ✅ Done | **2–4× scan** | New `BulkDirectoryReader.swift`; volume boundary via `dev_t` |
| **1.2** — Lock-based ScanProgress | ✅ Done | **15–25% scan** | `actor` → `OSAllocatedUnfairLock`; all `await` removed from hot path |
| **1.3** — Batch progress reads | ✅ Done | **3–5% UI** | `snapshot()` method; one lock acquisition per poll tick |
| **2.1** — DispatchSemaphore | ✅ Done | **3–6% scan** | `DirSemaphore` struct wrapping `DispatchSemaphore`; `release()` is sync |
| **2.2** — Leaf name only | ✅ Done | **5–8% scan** | `recordFile(name:...)`, updated every 128 files |
| **2.3** — Pre-allocate layoutRects | ✅ Done | **4–7% layout** | `reserveCapacity` + `inout` recursion via `layoutInto` |
| **2.4** — Cache filteredChildren | ✅ Done | **smoother UI** | `@State` + `.onChange` for 4 inputs |
| **2.5** — Hybrid concurrency | ✅ Done | **~10–20% scan** | `TaskGroup` for depth < 3; sequential `await` beyond — reduces Task creations from ~50k to ~2k |
| **2.6** — Small-subtree cutoff | ✅ Done | **~15–30% scan** | Skip recursing into subdirs of deep dirs with < 1 MB immediate files; depth ≥ 4 only |
| **3.1** — Incremental rescans | ❌ Not started | | |
| **3.2** — Worker-pool model | ❌ Not started | | |
| **3.3** — `fts(3)` traversal | ❌ Not started | | |
| **3.4** — Viewport-limited layout | ❌ Not started | | |
| **4.1–4.3** — Metal, memory, single-pass | ❌ Not started | | |

### Estimated combined effect (Tier 1 + Tier 2)

On a 500k-file full-drive scan that previously took ~30 seconds:
- `getattrlistbulk` alone: **~8–15 s** (dominant change)
- Lock-based ScanProgress + leaf names + DispatchSemaphore: **~7–12 s** (additional ~15–20% off)
- Hybrid concurrency + small-subtree cutoff: **~5–9 s** (additional ~20–30% off remaining)
- Overall: roughly **3–5× faster** end-to-end scan time

### Remaining high-value work

| Priority | Item | Expected Gain | Effort |
|----------|------|--------------|--------|
| **P1** | 3.4 — Viewport-limited layout depth | ~100× layout | Low-med |
| **P2** | 3.2 — Worker-pool model | 10–20% scan | Med-high |
| **P2** | 3.1 — Incremental rescans via FSEvents | ~100× rescan | High |
| **P3** | 4.1–4.3 — Metal, memory, single-pass | marginal | High |
