# DiskMapper — Phase 2: Squarified Treemap Layout Engine

## Status: Complete

---

## Files Created

| File | Purpose |
|---|---|
| `Sources/DiskMapper/Layout/LayoutRect.swift` | Output value: `CGRect` + `FileNode` reference + `depth` |
| `Sources/DiskMapper/Layout/TreemapLayout.swift` | Squarified layout algorithm |
| `Tests/DiskMapperTests/TreemapLayoutTests.swift` | 20 tests covering algorithm correctness |

---

## Algorithm: Squarified Treemap (Bruls, Huizing & van Wijk, 2000)

The squarified algorithm places items into strips, greedily adding each next item to
the current strip as long as doing so improves (or maintains) the worst aspect ratio.
When a new item would worsen ratios, the strip is flushed and a new one begins.

### Key formula

```
worst(row, w) = max( w² × max(row) / s²,  s² / (w² × min(row)) )
```

Where `s = sum(row)` and `w = min(rect.width, rect.height)` (shorter side = strip length).

### Orientation rule

| Remaining rect | Strip type | Consumes |
|---|---|---|
| landscape (width ≥ height) | Vertical — items stacked top-to-bottom | Width from left |
| portrait (height > width) | Horizontal — items laid left-to-right | Height from top |

### Layout pass

1. Normalize child sizes to pixel areas (proportional, summing to `rect.width × rect.height`)
2. Squarify: greedily fill strips, shrink remaining rect after each flush
3. Recurse into each directory child using its assigned rect

---

## Design Decisions

- **Iterative squarify** (not recursive) — avoids stack overflow for directories with thousands of entries
- **Areas pre-normalized at each level** — grandchildren fill their parent's rect independently, so proportionality is local and exact
- **`minVisibleSize` pruning** — rects below `minVisibleSize × minVisibleSize` pixels are excluded; directories with no visible children still emit their own rect (shown as solid blocks at low zoom)
- **Output order: parent before children** — renderers draw directory borders first, file fills on top
- **`worstAspect` is `internal`** — directly testable via `@testable import` without being part of the public API

---

## Test Coverage (20 tests)

| Test | What it verifies |
|---|---|
| `testWorstAspectPerfectSquare` | `area = w²` → ratio = 1.0 |
| `testWorstAspectEmptyRowReturnsInfinity` | Empty row → ∞ (never flush on empty) |
| `testWorstAspectZeroWReturnsInfinity` | w = 0 → ∞ (degenerate rect) |
| `testWorstAspectSymmetry` | `worst([a,b], w) == worst([b,a], w)` |
| `testWorstAspectImprovesWhenAddingGoodItem` | Adding equal item keeps ratio ≤ before |
| `testWorstAspectWorsenWhenAddingSmallItem` | Adding tiny item next to large one worsens ratio |
| `testSingleItemFillsRect` | Single area fills entire bounds |
| `testTwoEqualItemsInSquare` | Two equal areas each get half |
| `testFullCoverage` | Sum of rect areas ≈ total bounds area |
| `testLargerItemGetsLargerArea` | 3× size → 3× area (±0.1) |
| `testAspectRatiosReasonableForManyEqualItems` | All aspects < 10:1 for 9 equal items |
| `testAllRectsWithinBounds` | No rect escapes the bounds |
| `testEmptyAreasReturnsEmpty` | Empty input → empty output |
| `testZeroSizeRectReturnsZeros` | Zero-dimension rect → all `.zero` rects |
| `testLayoutSingleFileNode` | File node emits one rect = bounds at depth 0 |
| `testLayoutDirectoryEmitsParentAndChildren` | Dir + 2 files = 3 rects, depths 0/1/1 |
| `testLayoutChildrenFillParentRect` | Child areas sum = parent rect area |
| `testLayoutNestedDirectories` | 2-deep tree: 5 rects, containment verified |
| `testLayoutZeroSizeNodeReturnsEmpty` | Empty dir → no output |
| `testLayoutMinVisibleSizePruning` | Rects below threshold are excluded |
| `testRectOrderMatchesNodeOrder` | Largest area in index 0, etc. |

---

## Build Status

```
swift build  →  Build complete (no warnings)
swift test   →  Requires full Xcode.app
```

---

## Next: Phase 3 — SwiftUI Canvas Renderer

- SwiftUI `Canvas` drawing all `LayoutRect` values in a single pass
- Color by `FileKind` with a shared palette
- Hover highlight (tracking area / `onHover`)
- Click to drill down: zoom into a subtree
- Breadcrumb trail to navigate back up
