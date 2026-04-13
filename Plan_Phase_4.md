# DiskMapper — Phase 4: Sidebar Outline View

## Status: Complete

---

## Files Created / Modified

| File | Change |
|---|---|
| `Sources/DiskMapperApp/Views/NavigatorSidebar.swift` | **New** — outline list panel |
| `Sources/DiskMapperApp/Views/FileRowView.swift` | **New** — icon + name + size bar + size label |
| `Sources/DiskMapperApp/Views/TreemapViewModel.swift` | **Rewritten** — optional displayRoot, selectedID, lifted init |
| `Sources/DiskMapperApp/Views/TreemapView.swift` | **Modified** — accepts external `@ObservedObject` VM, adds selection highlight |
| `Sources/DiskMapperApp/Views/FileKindColor.swift` | **Modified** — added `iconName(for:)` |
| `Sources/DiskMapperApp/ContentView.swift` | **Rewritten** — shared VM, HStack layout, richer status bar |

---

## Architecture Change

`TreemapViewModel` is now created in `ContentView` as a `@StateObject` and passed down to both panels via `@ObservedObject`. This is the single source of truth for:

```
ContentView
  ├── @StateObject AppState           ← scan lifecycle
  ├── @StateObject TreemapViewModel   ← shared display state
  │     ├── displayRoot: FileNode?
  │     ├── layoutRects: [LayoutRect]
  │     ├── hoveredID: String?        ← set by either panel
  │     ├── selectedID: String?       ← set by sidebar click or treemap file tap
  │     └── navigationStack: [FileNode]
  ├── NavigatorSidebar(@ObservedObject viewModel)
  └── TreemapView(@ObservedObject viewModel)
```

---

## NavigatorSidebar Features

| Feature | Implementation |
|---|---|
| Sort by size | Default; children already sorted largest-first from scanner |
| Sort by name | `.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) }` |
| Row hover → treemap highlight | `.onHover { viewModel.hoveredID = node.id }` |
| Row click on file | `viewModel.selectedID = node.id` |
| Row click on directory | `viewModel.handleNavigate(to: node)` → drill down |
| Back button | `viewModel.navigateBack()` (visible when drilled in) |
| Empty / no-scan states | Placeholder views |
| Native selection style | `List(…, selection: $listSelection)` — system blue highlight |

---

## FileRowView Layout

```
[icon]  filename.ext                       [42.3 MB]
        [■■■■■■░░░░░░░░░░░░░░░░░░░░░░░]  ← size bar
```

- Icon: SF Symbol per `FileKind`, tinted with `FileKindColor`
- Size bar: `node.totalSize / parent.totalSize` proportion, RoundedRectangle
- Size label: monospaced, fixed 64 pt width, right-aligned

---

## Interaction Model (both panels)

| Action | Source | Effect |
|---|---|---|
| Mouse over treemap rect | Treemap | `hoveredID` → sidebar row glows, status bar updates |
| Mouse over sidebar row | Sidebar | `hoveredID` → treemap rect highlighted |
| Tap treemap directory | Treemap | `drillDown()` — breadcrumb grows, sidebar shows new level |
| Tap treemap file | Treemap | `selectedID` toggled — accent border on rect, status bar updates |
| Click sidebar directory | Sidebar | `drillDown()` — same as treemap tap |
| Click sidebar file | Sidebar | `selectedID` set — accent border on treemap rect |
| Breadcrumb tap | Breadcrumb | `navigate(to:)` — nav stack trimmed |
| Back button (sidebar header) | Sidebar | `navigateBack()` — pop nav stack |

---

## Key Bug Fixed

`.onChange(of: appState.rootNode)` requires `FileNode: Equatable`, but `FileNode` is a reference type without `Equatable` conformance. Fixed by observing `appState.rootNode?.id` (a `String?`, which is `Equatable`).

---

## Build Status

```
swift build  →  Build complete (no warnings)
swift run DiskMapperApp  →  Launches with sidebar + treemap side by side
```

---

## Next: Phase 5 — Toolbar, Info Bar & Finder Integration

- Reveal in Finder (right-click context menu, double-click)
- Move to Trash from context menu
- Copy path to clipboard
- Last-modified date in sidebar + status bar
- Rescan a subtree
- Resizable sidebar (drag handle)
