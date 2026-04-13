# DiskMapper — Phase 1: File Scanner & Data Model

## Status: Complete

---

## Files Created

| File | Purpose |
|---|---|
| `Package.swift` | SPM manifest, macOS 13+ target |
| `Sources/DiskMapper/Scanner/FileKind.swift` | 8 file categories, classified by extension |
| `Sources/DiskMapper/Scanner/FileNode.swift` | Tree node — `totalSize`, `computeTotals()`, `sortChildren()` |
| `Sources/DiskMapper/Scanner/ScanProgress.swift` | Actor — thread-safe file/dir counts, errors, cancellation |
| `Sources/DiskMapper/Scanner/DiskScanner.swift` | Async recursive scanner using `TaskGroup` |
| `Tests/DiskMapperTests/ScannerTests.swift` | 18 tests covering structure, sizes, sorting, symlinks, progress, cancellation |

---

## Design Decisions

- **`DiskScanner` is a plain `struct`** (not an actor) so its methods run freely in parallel `TaskGroup` child tasks with no serialization bottleneck.
- **Symlinks are skipped** via `URLResourceKey.isSymbolicLinkKey` to prevent directory cycles and double-counting.
- **`totalSize` is computed in a single bottom-up pass** (`computeTotals()`) after the full tree is built — not during concurrent construction, which avoids data races.
- **`ScanProgress` is an actor** providing thread-safe counters for files scanned, directories scanned, errors encountered, and a cancellation flag checked between items.
- **`URLResourceValues` batch-fetches** all needed attributes (name, isDirectory, isSymbolicLink, allocatedSize) in one call per URL — much faster than individual `stat()` calls.
- **`"ts"` extension maps to `.code`** (TypeScript), not `.video` (transport stream), since `.mts`/`.m2ts` cover video transport streams unambiguously.

---

## FileKind Categories

| Kind | Example Extensions |
|---|---|
| `.image` | jpg, png, heic, webp, tiff, gif, bmp, svg |
| `.video` | mp4, mov, avi, mkv, m4v, wmv, flv, webm, mts, m2ts |
| `.audio` | mp3, aac, wav, flac, m4a, ogg, opus, aiff |
| `.document` | pdf, doc, docx, xls, txt, md, pages, numbers, epub |
| `.archive` | zip, tar, gz, bz2, 7z, rar, dmg, pkg, iso |
| `.code` | swift, py, js, ts, go, rs, java, c, cpp, json, yaml, html, css |
| `.executable` | app, dylib, framework, xcframework |
| `.other` | everything else |

---

## Test Coverage (18 tests)

| Test | What it verifies |
|---|---|
| `testScanEmptyDirectory` | Empty dir returns zero children and zero size |
| `testScanFlatFiles` | Files in root are counted correctly |
| `testScanNestedDirectories` | Subdirectory structure is preserved |
| `testTotalSizeEqualsChildrenSum` | Root `totalSize` == sum of children |
| `testNestedTotalSizePropagates` | Nested file sizes bubble up to root |
| `testChildrenSortedLargestFirst` | `sortChildren()` orders by size descending |
| `testSymlinksAreSkipped` | Symlinks excluded from tree |
| `testProgressCounts` | `scannedFiles` and `scannedDirectories` are accurate |
| `testCancellationStopsEarly` | Setting `isCancelled` halts scanning |
| `testScanFileThrows` | Passing a file (not dir) throws `ScanError.notADirectory` |
| `testFileKindImages` | Image extensions classify correctly |
| `testFileKindVideos` | Video extensions classify correctly |
| `testFileKindAudio` | Audio extensions classify correctly |
| `testFileKindDocuments` | Document extensions classify correctly |
| `testFileKindArchives` | Archive extensions classify correctly |
| `testFileKindCode` | Code extensions classify correctly |
| `testFileKindExecutable` | Executable extensions classify correctly |
| `testFileKindOther` | Unknown/empty extensions → `.other` |
| `testFileKindCaseInsensitive` | `.JPG`, `.MP4`, `.SWIFT` all classify correctly |
| `testFileNodeDescription` | `CustomStringConvertible` output contains filename |

---

## Build Status

```
swift build  →  Build complete (no warnings)
swift test   →  Requires full Xcode.app (XCTest unavailable with Command Line Tools only)
```

---

## Next: Phase 2 — Squarified Treemap Layout Engine

- Pure value-type layout: `[FileNode] → [LayoutRect]`
- Squarified algorithm (better aspect ratios than slice-and-dice)
- Computed off the main thread; cached until resize or rescan
- Unit tests verifying coverage (all space filled), aspect ratios, and proportionality
