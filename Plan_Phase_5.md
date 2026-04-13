# Phase 5 — Finder Integration & Polish

## Goals
- Finder integration: reveal in Finder, copy path, move to Trash
- Context menus in both the treemap Canvas and the sidebar list
- Double-click in treemap to reveal in Finder
- Modification dates shown in sidebar rows and status bar
- Rescan button (re-use last scanned URL)
- Resizable sidebar divider with resize cursor
- Richer status bar (icon + kind + date for hovered/selected node)
- Bug fix: directory color was `.clear` (invisible in sidebar icons)

## Files Changed

### `Sources/DiskMapper/Scanner/FileNode.swift`
- Added `public let modifiedDate: Date?` property
- Updated `init` with `modifiedDate: Date? = nil` parameter

### `Sources/DiskMapper/Scanner/DiskScanner.swift`
- Added `.contentModificationDateKey` to `resourceKeys`
- Passes `modifiedDate: values.contentModificationDate` when creating file nodes

### `Sources/DiskMapperApp/Views/FileKindColor.swift`
- Fixed `.directory` color from `.clear` → `Color(hue: 0.12, saturation: 0.55, brightness: 0.95)` (macOS folder yellow)
- The treemap still skips directory fills via `where !lr.node.isDirectory`; this only affects sidebar icons

### `Sources/DiskMapperApp/AppState.swift`
- Added `private(set) var lastScannedURL: URL?`
- `beginScan(url:)` now stores `lastScannedURL = url`
- Added `func rescan()` — calls `beginScan(url: lastScannedURL!)` if set

### `Sources/DiskMapperApp/FinderActions.swift` *(new file)*
- `reveal(_:)` — `NSWorkspace.shared.activateFileViewerSelecting`
- `copyPath(_:)` — writes path to `NSPasteboard.general`
- `moveToTrash(_:)` — `FileManager.default.trashItem`

### `Sources/DiskMapperApp/Views/FileRowView.swift`
- Added modification date label below the size bar for non-directory nodes

### `Sources/DiskMapperApp/Views/TreemapView.swift`
- Added `@State private var trashTarget` + `showingTrashDialog` for trash confirmation
- Double-tap gesture (`count: 2`) → `FinderActions.reveal`
- Context menu targeting `viewModel.hoveredNode`: Reveal in Finder, Copy Path, Move to Trash…
- `.confirmationDialog` for destructive trash action

### `Sources/DiskMapperApp/Views/NavigatorSidebar.swift`
- Added `@State private var trashTarget` + `showingTrashDialog`
- `.contextMenu` on each List row: Reveal in Finder, Copy Path, Move to Trash…
- `.confirmationDialog` on the root VStack

### `Sources/DiskMapperApp/ContentView.swift`
- `@State private var sidebarWidth: CGFloat = 280`
- `sidebarHandle` property: 6pt drag zone between sidebar and treemap
  - `DragGesture.onChanged` clamps width to `[160, 520]`
  - `onHover` pushes/pops `NSCursor.resizeLeftRight`
- Rescan button shown when `appState.lastScannedURL != nil && !appState.isScanning`
- `statusContent` `@ViewBuilder`: shows icon + name + kind + size + modified date for hovered/selected node

## Bug Fixes
- **Curly-quote string interpolation**: `"Move "\(name)" to Trash"` caused a Swift parse error because the inner ASCII `"` terminated the string literal prematurely. Fixed by using `\u{201C}` and `\u{201D}` Unicode escapes.

## Build Status
`swift build` → **Build complete** (no errors, XCTest platform warning is benign — Command Line Tools only).
