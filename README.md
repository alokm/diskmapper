# DiskMapper

A fast macOS disk usage visualizer — a modern fast, stable, Swift-native interpretation, inspired by the amazing but old and unstable [Disk Inventory X](http://www.derlien.com). Scans your drive using `getattrlistbulk(2)` and renders an interactive squarified treemap with SwiftUI.

![DiskMapper screenshot](https://github.com/alokm/diskmapper/raw/main/screenshot.png)

## Features

- Interactive treemap with drill-down navigation
- Color themes: By Kind, By Size (perceptual gradient), Monochrome
- Live search and filter in the sidebar
- Sort by size, name, or date modified
- Hidden files toggle
- Reveal in Finder, copy path, move to trash
- Scan any folder or full volume

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (for `swift` compiler)

## Install dependencies

DiskMapper has no third-party dependencies. Only the Xcode Command Line Tools are required.

**Check if already installed:**

```bash
xcode-select -p
```

**Install if missing:**

```bash
xcode-select --install
```

Follow the on-screen prompt. This installs `swift`, `git`, and the macOS SDK (~200 MB).

## Build and run

```bash
# Clone the repo
git clone https://github.com/alokm/diskmapper.git
cd diskmapper

# Build in release mode
swift build -c release

# Run
.build/release/DiskMapperApp
```

Or build and run in one step:

```bash
swift run -c release DiskMapperApp
```

> **Note:** macOS will prompt for Full Disk Access the first time you scan protected directories (Desktop, Documents, Downloads). Grant access in **System Settings → Privacy & Security → Full Disk Access**.

## Run tests

```bash
swift test
```

## Project structure

```
Sources/
├── DiskMapper/                    # Library: scanner + layout engine
│   ├── Scanner/
│   │   ├── FileNode.swift         # Tree node with lazy path computation
│   │   ├── FileKind.swift         # 8 file categories by extension
│   │   ├── DiskScanner.swift      # Async recursive scanner
│   │   ├── BulkDirectoryReader.swift  # getattrlistbulk(2) I/O layer
│   │   └── ScanProgress.swift     # Thread-safe progress tracking
│   └── Layout/
│       ├── TreemapLayout.swift    # Squarified treemap algorithm
│       └── LayoutRect.swift       # Layout output type
└── DiskMapperApp/                 # App: SwiftUI frontend
    ├── AppState.swift             # Scan lifecycle and state
    ├── ContentView.swift          # Root layout
    ├── FinderActions.swift        # Reveal / copy path / trash
    └── Views/
        ├── TreemapView.swift      # Canvas renderer
        ├── NavigatorSidebar.swift # File list with search + sort
        ├── TreemapViewModel.swift # Shared view state
        ├── FileKindColor.swift    # Color themes and palette
        ├── FileRowView.swift      # Sidebar row view
        └── BreadcrumbView.swift   # Navigation breadcrumb
Tests/
└── DiskMapperTests/
    ├── ScannerTests.swift         # Scanner unit tests
    └── TreemapLayoutTests.swift   # Layout algorithm tests
```

## Performance

On a 500k-file drive, DiskMapper completes a full scan in roughly 3–5× less time than tools using `FileManager.contentsOfDirectory`. Key optimizations:

- **`getattrlistbulk(2)`** — single syscall per directory (vs. one per file)
- **`SlotPool`** — 16 × 256 KB I/O buffers pre-allocated once, reused throughout
- **Hybrid concurrency** — `TaskGroup` for the top 3 depth levels; sequential scan below, keeping Swift Task count to ~2k instead of ~50k
- **Small-subtree cutoff** — directories deeper than level 4 with < 1 MB of immediate files skip recursing into subdirectories
- **Lazy paths** — `FileNode` stores only the leaf name; full path computed on demand by walking the weak parent chain

## License

MIT
