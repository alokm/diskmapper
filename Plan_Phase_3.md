# DiskMapper — Phase 3: SwiftUI Canvas Renderer

## Status: Complete

---

## Files Created

| File | Purpose |
|---|---|
| `Package.swift` | Added `DiskMapperApp` executableTarget |
| `Sources/DiskMapperApp/DiskMapperApp.swift` | `@main` App entry point, window sizing |
| `Sources/DiskMapperApp/AppState.swift` | `@MainActor ObservableObject` — scan lifecycle + progress polling |
| `Sources/DiskMapperApp/ContentView.swift` | Root view: toolbar, file picker, legend, status bar |
| `Sources/DiskMapperApp/Views/FileKindColor.swift` | `FileKind → Color` palette + legend metadata |
| `Sources/DiskMapperApp/Views/TreemapViewModel.swift` | Layout state, hover, drill-down navigation |
| `Sources/DiskMapperApp/Views/TreemapView.swift` | SwiftUI `Canvas` renderer + gestures |
| `Sources/DiskMapperApp/Views/BreadcrumbView.swift` | Horizontal navigation path strip |

---

## Architecture

```
ContentView
  ├── AppState (@StateObject)         ← scan lifecycle, progress
  ├── toolbar                         ← scan button, progress text, legend
  ├── TreemapView (root: FileNode)
  │     ├── TreemapViewModel (@StateObject)  ← layout rects, hover, nav stack
  │     ├── BreadcrumbView             ← shown when drilled in
  │     └── Canvas                    ← single-pass renderer
  └── statusBar                       ← path + total size
```

---

## Canvas Rendering Pipeline

Each render call draws in 5 ordered passes (parent rects before children):

| Pass | What | How |
|---|---|---|
| 1 | Dark background | `context.fill(fullRect)` |
| 2 | File fills | `context.fill(rect)` with `FileKindColor` |
| 3 | Cell borders | `context.stroke` — 0.5px dark for files, 1px white@18% for directories |
| 4 | Text labels | `context.draw(Text, in: rect)` for rects ≥ 40×14 px |
| 5 | Hover highlight | 4px outer glow + 2px inner white border |

---

## Key Design Decisions

- **`Text` stays as `Text` in Canvas** — `lineLimit` / `truncationMode` are `View` modifiers that change the type to `some View`, which `GraphicsContext.draw` doesn't accept. Labels are clipped by the `in: rect` draw variant instead.
- **`TreemapViewModel` stores `canvasSize`** — so navigation actions (`handleTap`, `navigate`, `navigateBack`) can re-trigger layout without the GeometryReader needing to fire an event.
- **Layout runs in a `Task.detached`** — the `TreemapLayout` computation is CPU-bound and would block the main thread for large trees. The detached task hops off MainActor, then posts results back.
- **Progress polling via a parallel `Task`** — `ScanProgress` is an actor; a lightweight Task wakes every 150 ms during scanning to copy counts to `@Published` properties on the main actor.
- **`DragGesture` replaced by `onTapGesture(coordinateSpace:)`** — available on macOS 13+ and gives tap location cleanly without the drag/click ambiguity of `DragGesture(minimumDistance: 0)`.

---

## Interaction Model

| Gesture | Action |
|---|---|
| Hover | Highlights deepest rect under cursor (file or directory) |
| Single tap on directory | Drills down; pushes current root to nav stack |
| Single tap on file | No-op in Phase 3 (Phase 5: reveal in Finder) |
| Breadcrumb tap | Navigates back to that ancestor; truncates nav stack |

---

## Build Status

```
swift build  →  Build complete (no warnings)
swift run DiskMapperApp  →  Launches macOS window (requires display)
```

> **Note:** SPM-built executables are not sandboxed, so they have full user-level filesystem access — no entitlements needed for dev/testing. A distribution build will need an Xcode project + entitlements.

---

## Next: Phase 4 — Sidebar Outline View

- `NSOutlineView` (via `NSViewRepresentable`) or SwiftUI `List` showing directory tree
- In-line size bars (proportional to parent)
- Selection synced with treemap hover/click (bidirectional)
- Sortable columns: name, size, kind, last modified
