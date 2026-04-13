import XCTest
import CoreGraphics
@testable import DiskMapper

final class TreemapLayoutTests: XCTestCase {

    let layout = TreemapLayout(minVisibleSize: 1.0)
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

    // MARK: - Test helpers

    func makeFile(_ name: String, size: Int64) -> FileNode {
        FileNode(name: name, path: "/\(name)", isDirectory: false,
                 allocatedSize: size, kind: .other)
    }

    func makeDir(_ name: String, children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, path: "/\(name)", isDirectory: true,
                            allocatedSize: 0, kind: .directory, children: children)
        node.computeTotals()
        return node
    }

    // MARK: - worstAspect

    func testWorstAspectPerfectSquare() {
        // A single item whose area equals w² should produce aspect ratio of 1.0
        let w: CGFloat = 100
        let area = w * w  // 10000 — strip item will be a perfect square
        let ratio = layout.worstAspect(row: [area], w: w)
        XCTAssertEqual(ratio, 1.0, accuracy: 1e-9)
    }

    func testWorstAspectEmptyRowReturnsInfinity() {
        XCTAssertEqual(layout.worstAspect(row: [], w: 100), .greatestFiniteMagnitude)
    }

    func testWorstAspectZeroWReturnsInfinity() {
        XCTAssertEqual(layout.worstAspect(row: [100], w: 0), .greatestFiniteMagnitude)
    }

    func testWorstAspectSymmetry() {
        // worst([a, b], w) should be the same as worst([b, a], w)
        let row1: [CGFloat] = [600, 400]
        let row2: [CGFloat] = [400, 600]
        XCTAssertEqual(layout.worstAspect(row: row1, w: 100),
                       layout.worstAspect(row: row2, w: 100), accuracy: 1e-9)
    }

    func testWorstAspectImprovesWhenAddingGoodItem() {
        let w: CGFloat = 100
        // One item at w² → ratio = 1.0 (perfect).  Adding another equal item should keep ratio = 1.0.
        let a = w * w  // 10000
        let before = layout.worstAspect(row: [a], w: w)        // = 1.0
        let after  = layout.worstAspect(row: [a, a], w: w)     // also 1.0
        XCTAssertLessThanOrEqual(after, before + 1e-9)
    }

    func testWorstAspectWorsenWhenAddingSmallItem() {
        let w: CGFloat = 100
        let big: CGFloat = 9000
        let small: CGFloat = 100
        let before = layout.worstAspect(row: [big], w: w)
        let after  = layout.worstAspect(row: [big, small], w: w)
        // Adding a tiny item next to a large one creates a very thin sliver.
        XCTAssertGreaterThan(after, before)
    }

    // MARK: - Single-item squarify

    func testSingleItemFillsRect() {
        let areas: [CGFloat] = [bounds.width * bounds.height]
        let rects = layout.squarify(areas: areas, in: bounds)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].origin.x, bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(rects[0].origin.y, bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(rects[0].width,    bounds.width,    accuracy: 0.5)
        XCTAssertEqual(rects[0].height,   bounds.height,   accuracy: 0.5)
    }

    // MARK: - Two equal items

    func testTwoEqualItemsInSquare() {
        let sq = CGRect(x: 0, y: 0, width: 100, height: 100)
        let area: CGFloat = 50 * 100   // each half of sq
        let rects = layout.squarify(areas: [area, area], in: sq)
        XCTAssertEqual(rects.count, 2)
        let totalCovered = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalCovered, 10000, accuracy: 1.0)
        // Each item should have the same area
        XCTAssertEqual(rects[0].width * rects[0].height,
                       rects[1].width * rects[1].height, accuracy: 1.0)
    }

    // MARK: - Coverage (all area is filled)

    func testFullCoverage() {
        let totalArea = bounds.width * bounds.height
        let areas: [CGFloat] = [3000, 2000, 1500, 1000, 500, 800, 700, 500]
        // Normalize to fill the rect
        let sum = areas.reduce(0, +)
        let normalized = areas.map { $0 / sum * totalArea }
        let rects = layout.squarify(areas: normalized, in: bounds)
        let covered = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertEqual(covered, totalArea, accuracy: 2.0)
    }

    // MARK: - Proportionality

    func testLargerItemGetsLargerArea() {
        let totalArea = bounds.width * bounds.height
        // Item 0 is 3× larger than item 1
        let areas: [CGFloat] = [0.75 * totalArea, 0.25 * totalArea]
        let rects = layout.squarify(areas: areas, in: bounds)
        let area0 = rects[0].width * rects[0].height
        let area1 = rects[1].width * rects[1].height
        XCTAssertGreaterThan(area0, area1)
        // Ratio should be approximately 3:1
        XCTAssertEqual(area0 / area1, 3.0, accuracy: 0.1)
    }

    // MARK: - Aspect ratio quality

    func testAspectRatiosReasonableForManyEqualItems() {
        let sq = CGRect(x: 0, y: 0, width: 300, height: 300)
        let n = 9
        let eachArea = sq.width * sq.height / CGFloat(n)
        let areas = Array(repeating: eachArea, count: n)
        let rects = layout.squarify(areas: areas, in: sq)
        for r in rects {
            guard r.width > 0, r.height > 0 else { continue }
            let aspect = max(r.width, r.height) / min(r.width, r.height)
            // Squarified should keep aspect ratios well below 10:1
            XCTAssertLessThan(aspect, 10.0, "Unexpected aspect \(aspect) for rect \(r)")
        }
    }

    // MARK: - No rects outside bounds

    func testAllRectsWithinBounds() {
        let totalArea = bounds.width * bounds.height
        let sizes: [CGFloat] = [5, 3, 2, 8, 1, 4]
        let sum = sizes.reduce(0, +)
        let areas = sizes.map { $0 / sum * totalArea }
        let rects = layout.squarify(areas: areas, in: bounds)
        for r in rects {
            XCTAssertGreaterThanOrEqual(r.minX, bounds.minX - 0.5)
            XCTAssertGreaterThanOrEqual(r.minY, bounds.minY - 0.5)
            XCTAssertLessThanOrEqual(r.maxX,    bounds.maxX + 0.5)
            XCTAssertLessThanOrEqual(r.maxY,    bounds.maxY + 0.5)
        }
    }

    // MARK: - Empty and degenerate inputs

    func testEmptyAreasReturnsEmpty() {
        let rects = layout.squarify(areas: [], in: bounds)
        XCTAssertTrue(rects.isEmpty)
    }

    func testZeroSizeRectReturnsZeros() {
        let zeroRect = CGRect(x: 0, y: 0, width: 0, height: 100)
        let rects = layout.squarify(areas: [100], in: zeroRect)
        XCTAssertTrue(rects.allSatisfy { $0 == .zero })
    }

    // MARK: - layout(node:in:) integration

    func testLayoutSingleFileNode() {
        let file = makeFile("doc.pdf", size: 1024)
        let rects = layout.layout(node: file, in: bounds)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].rect, bounds)
        XCTAssertEqual(rects[0].depth, 0)
        XCTAssertEqual(rects[0].node.name, "doc.pdf")
    }

    func testLayoutDirectoryEmitsParentAndChildren() {
        let dir = makeDir("root", children: [
            makeFile("a.txt", size: 3000),
            makeFile("b.txt", size: 1000),
        ])
        let rects = layout.layout(node: dir, in: bounds)
        // 1 directory + 2 files = 3 rects
        XCTAssertEqual(rects.count, 3)
        // First rect is the directory itself at depth 0
        XCTAssertTrue(rects[0].node.isDirectory)
        XCTAssertEqual(rects[0].depth, 0)
        // Children are at depth 1
        XCTAssertTrue(rects.dropFirst().allSatisfy { $0.depth == 1 })
    }

    func testLayoutChildrenFillParentRect() {
        let dir = makeDir("root", children: [
            makeFile("x.bin", size: 6000),
            makeFile("y.bin", size: 4000),
        ])
        let rects = layout.layout(node: dir, in: bounds)
        let childRects = rects.filter { !$0.node.isDirectory }
        let childArea = childRects.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }
        let parentArea = bounds.width * bounds.height
        XCTAssertEqual(childArea, parentArea, accuracy: 2.0)
    }

    func testLayoutNestedDirectories() {
        let inner = makeDir("inner", children: [
            makeFile("i1.dat", size: 2000),
            makeFile("i2.dat", size: 1000),
        ])
        let outer = makeDir("outer", children: [
            inner,
            makeFile("top.dat", size: 3000),
        ])
        outer.computeTotals()

        let rects = layout.layout(node: outer, in: bounds)
        // outer(1) + inner(1) + i1(1) + i2(1) + top(1) = 5
        XCTAssertEqual(rects.count, 5)

        // inner directory rect should be contained within outer
        let innerRect = rects.first { $0.node.name == "inner" }!.rect
        XCTAssertGreaterThanOrEqual(innerRect.minX, bounds.minX - 0.5)
        XCTAssertGreaterThanOrEqual(innerRect.minY, bounds.minY - 0.5)
        XCTAssertLessThanOrEqual(innerRect.maxX, bounds.maxX + 0.5)
        XCTAssertLessThanOrEqual(innerRect.maxY, bounds.maxY + 0.5)

        // Children of inner should be within inner's rect
        for name in ["i1.dat", "i2.dat"] {
            let childRect = rects.first { $0.node.name == name }!.rect
            XCTAssertGreaterThanOrEqual(childRect.minX, innerRect.minX - 0.5)
            XCTAssertGreaterThanOrEqual(childRect.minY, innerRect.minY - 0.5)
            XCTAssertLessThanOrEqual(childRect.maxX, innerRect.maxX + 0.5)
            XCTAssertLessThanOrEqual(childRect.maxY, innerRect.maxY + 0.5)
        }
    }

    func testLayoutZeroSizeNodeReturnsEmpty() {
        let empty = makeDir("empty", children: [])
        let rects = layout.layout(node: empty, in: bounds)
        // Zero totalSize → no output
        XCTAssertTrue(rects.isEmpty)
    }

    func testLayoutMinVisibleSizePruning() {
        // Give a tiny bounds so everything is below the threshold
        let tinyLayout = TreemapLayout(minVisibleSize: 100)
        let smallBounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let file = makeFile("small.txt", size: 512)
        let rects = tinyLayout.layout(node: file, in: smallBounds)
        XCTAssertTrue(rects.isEmpty)
    }

    // MARK: - Order preservation

    func testRectOrderMatchesNodeOrder() {
        let totalArea = bounds.width * bounds.height
        let areas: [CGFloat] = [0.5 * totalArea, 0.3 * totalArea, 0.2 * totalArea]
        let rects = layout.squarify(areas: areas, in: bounds)
        // Larger areas should correspond to larger rects
        XCTAssertGreaterThan(rects[0].width * rects[0].height,
                             rects[1].width * rects[1].height)
        XCTAssertGreaterThan(rects[1].width * rects[1].height,
                             rects[2].width * rects[2].height)
    }
}
