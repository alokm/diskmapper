
# DiskMapper — Implementation Plan

A modern macOS clone of Disk Inventory X with fast scanning and a native SwiftUI interface.

---

## Architecture & Tech Stack

**Language:** Swift 5.9+  
**UI:** SwiftUI + AppKit where needed  
**Rendering:** SwiftUI `Canvas` (single-pass, no per-cell views)  
**Concurrency:** Swift structured concurrency (`async`/`await`, `TaskGroup`, `actor`)

---

## Core Components

### 1. Disk Scanner
- Walk the file system using `URLResourceValues` (batch-fetch attributes — much faster than `stat()` per-file)
- **Bounded concurrency** via `DirSemaphore` actor (default: 16 simultaneous `contentsOfDirectory` calls; semaphore slot released immediately after the call, before child tasks run)
- **Volume-boundary detection** — by default never crosses volume boundary (skips `/Volumes/*`, Time Machine disks, network shares); optional opt-in via `crossVolumeBoundaries: true`
- **Hard skip list** — macOS virtual/pseudo-filesystems: `/dev`, `/net`, `/home`, `/System/Volumes`, `/private/var/vm`, `/private/var/db/uuidtext`, `/.vol`, `/.Spotlight-V100`, `/.fseventsd`, `/.MobileBackups`, `/private/var/db/dyld`
- Handle permission errors gracefully (skip + record)
- Support scanning any folder or volume root
- Report scan progress as `scannedBytes / volumeUsedBytes` for a determinate progress bar

### 2. Treemap Layout Engine
- **Squarified Treemap** algorithm (Bruls, Huizing & van Wijk 2000)
- Pure value-type layout: `[FileNode] → [LayoutRect]`
- Optional `nodeFilter` predicate for client-side hiding (e.g. dotfiles)
- Recomputed off the main thread; debounced on resize

### 3. UI Layers

| Panel | Description |
|---|---|
| **Sidebar** | SwiftUI `List` with live search field, three sort modes (size / name / date), hidden-files toggle |
| **Treemap Canvas** | SwiftUI `Canvas` — hover highlight, drill-down, search match rings, colour themes |
| **Breadcrumb** | Navigate back to any ancestor with a single click |
| **Toolbar** | Scan, Rescan (⌘R), Cancel, hidden-files toggle, colour-theme picker, scan progress bar + items/s rate |
| **Status Bar** | Hovered/selected node: icon, kind, size, date; or root path + total size |

### 4. Color & Visual Design
- Three colour themes switchable in the toolbar:
  - **By Kind** — file-type palette (images=green, video=blue, audio=teal, documents=amber, archives=purple, code=red-orange)
  - **By Size** — log-scale heat map: cool blue (small) → warm red (large)
  - **Monochrome** — greyscale brightness proportional to size
- Subtle borders between cells; directory outlines in white
- Labels drawn inside cells larger than 40 × 14 pt

---

## Performance

- **Scanning**: Each directory read via a single `getattrlistbulk(2)` syscall (replaces `FileManager.contentsOfDirectory` + per-file `url.resourceValues`). Concurrent `TaskGroup` for top 3 depth levels; sequential `await` beyond depth 3 to avoid ~50k Task creations. `SlotPool` pre-allocates 16 × 256 KB I/O buffers once at scan start. Volume-boundary detection via `dev_t` device ID.
- **Small-subtree cutoff**: Directories at depth ≥ 4 with < 1 MB of immediate files skip recursing into subdirectories entirely — subdirs are replaced with empty placeholder nodes. Eliminates scanning thousands of tiny deep leaves (`.git/objects`, `node_modules` internals, etc.).
- **Progress tracking**: `ScanProgress` uses `OSAllocatedUnfairLock` (not an actor) — `recordBatch(directoryName:fileCount:bytes:)` is called once per directory (not per file), fully synchronous with no suspension points. UI poller reads all fields via a single `snapshot()` call.
- **Layout**: Computed in a `Task.detached(priority: .userInitiated)` closure; pre-allocated output array via `reserveCapacity` + `inout` recursion. Results animate in with `.easeInOut(0.18 s)`.
- **Rendering**: Single-pass `Canvas` — 5 drawing passes (background, fills, borders, labels, highlights)
- **Memory**: `FileNode` stores only leaf `name`; full `path` computed on demand by walking weak `parent` chain (saves ~40 MB on 500k-file scan). Only the scan root stores `_absolutePath`.
- **Sidebar**: `filteredChildren` cached as `@State`; recomputed only when sort order, search text, hidden-files toggle, or display root changes.

---

## Project Structure

```
Sources/
├── DiskMapper/                   # Library target
│   ├── Scanner/
│   │   ├── FileNode.swift           # Tree node (lazy path, weak parent, size, kind, children)
│   │   ├── FileKind.swift           # 8 categories classified by extension
│   │   ├── DiskScanner.swift        # Recursive scanner: hybrid concurrency + small-subtree cutoff
│   │   ├── BulkDirectoryReader.swift # SlotPool + scanDirectoryEntries closure API
│   │   └── ScanProgress.swift      # Lock-based progress: OSAllocatedUnfairLock + snapshot()
│   └── Layout/
│       ├── TreemapLayout.swift   # Squarified algorithm + nodeFilter
│       └── LayoutRect.swift     # (CGRect, FileNode, depth)
└── DiskMapperApp/                # Executable target
    ├── DiskMapperApp.swift       # @main
    ├── AppState.swift            # Scan lifecycle, progress polling, items/sec
    ├── FinderActions.swift       # reveal / copyPath / moveToTrash
    ├── ContentView.swift         # Root layout: toolbar, sidebar, treemap, status bar
    ├── Assets.xcassets/          # AppIcon (generated by Scripts/generate_icon.py)
    └── Views/
        ├── TreemapViewModel.swift   # Shared state: theme, search, hidden, layout
        ├── TreemapView.swift        # Canvas renderer
        ├── NavigatorSidebar.swift   # List + search + sort (size/name/date)
        ├── FileRowView.swift        # Sidebar row: icon, name, size bar, date
        ├── FileKindColor.swift      # ColorTheme enum + colour palette
        └── BreadcrumbView.swift     # Navigation path strip
Tests/
└── DiskMapperTests/
    ├── ScannerTests.swift           # 18 tests
    └── TreemapLayoutTests.swift     # 20+ tests
Scripts/
└── generate_icon.py               # Generates AppIcon PNGs (pure Python, no deps)
```

---

## Key Features

- **Drill-down navigation**: click a rectangle or sidebar row to zoom into a subtree; breadcrumb trail to go back
- **Bi-directional sync**: hover/selection synced between sidebar and treemap in real time
- **Search/filter**: type in the sidebar search field to filter rows; matching cells get a yellow ring in the treemap
- **Hidden files**: eye-icon toggle hides/shows dotfiles in both panels without rescanning
- **Sort**: sidebar supports size (default), name A→Z, or date modified (newest first)
- **Colour themes**: By Kind / By Size / Monochrome — switchable in the toolbar
- **Finder integration**: double-click reveals in Finder; right-click for Reveal / Copy Path / Move to Trash
- **Scan progress**: determinate progress bar (% of volume used capacity) + rolling items/sec rate when scanning a full volume; indeterminate spinner for subdirectory scans
- **Rescan**: ⌘R re-runs the last scan without re-picking the folder

---

## Phased Delivery

| Phase | Deliverable |
|---|---|
| **1** | File scanner + FileNode tree + unit tests |
| **2** | Squarified treemap layout algorithm + tests |
| **3** | SwiftUI Canvas renderer with hover/click |
| **4** | Sidebar outline view + selection sync |
| **5** | Toolbar, info bar, Finder integration, resizable sidebar, rescan, modification dates |
| **6** | Polish: colour themes, search/filter, hidden-files toggle, keyboard shortcuts, drill-down animation, hover tooltip, app icon |
| **7** | Sort by date, scanner stability (bounded concurrency + macOS skip list), determinate scan progress bar + items/sec rate |
| **8** | Performance: `getattrlistbulk` I/O (2–4× scan), lock-based `ScanProgress` (no actor), `DispatchSemaphore`, leaf-name-only progress, pre-allocated layout array, cached sidebar filter, lazy paths, progress batching, inline build + `SlotPool`, hybrid concurrency, small-subtree cutoff |
