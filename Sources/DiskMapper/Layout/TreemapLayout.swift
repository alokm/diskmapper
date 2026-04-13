import CoreGraphics

/// Squarified treemap layout engine.
///
/// Converts a `FileNode` tree into a flat array of positioned `LayoutRect`
/// values using the squarified algorithm (Bruls, Huizing & van Wijk, 2000).
///
/// **Orientation rule** — for each remaining rect:
/// - landscape (width ≥ height): items are stacked in a *vertical* strip
///   that consumes width from the left.
/// - portrait  (height > width): items are placed in a *horizontal* strip
///   that consumes height from the top.
///
/// In both cases the shorter side `w = min(width, height)` is used as the
/// strip length for computing aspect-ratio quality.
///
/// **Output** — one `LayoutRect` per node (file or directory) whose assigned
/// rect is at least `minVisibleSize × minVisibleSize` pixels. Directory rects
/// contain their children's rects; renderers should draw parent before child.
public struct TreemapLayout: Sendable {

    /// Rects smaller than this in either dimension are pruned from the output.
    public var minVisibleSize: CGFloat

    /// Optional predicate applied to each node's children before layout.
    /// Nodes that fail the predicate are hidden from the treemap (but still
    /// contribute to their parent's `totalSize`).
    public var nodeFilter: (@Sendable (FileNode) -> Bool)?

    public init(
        minVisibleSize: CGFloat = 2.0,
        nodeFilter: (@Sendable (FileNode) -> Bool)? = nil
    ) {
        self.minVisibleSize = minVisibleSize
        self.nodeFilter = nodeFilter
    }

    // MARK: - Public API

    /// Lay out `node` and all visible descendants within `bounds`.
    ///
    /// - Parameters:
    ///   - node:   Root of the subtree to lay out.
    ///   - bounds: The rectangle to fill. Coordinate system is caller's choice.
    ///   - depth:  Starting depth value written into each `LayoutRect`; defaults to 0.
    /// - Returns: A flat array of `LayoutRect`, parent rects before child rects.
    public func layout(node: FileNode, in bounds: CGRect, depth: Int = 0) -> [LayoutRect] {
        guard node.totalSize > 0,
              bounds.width  >= minVisibleSize,
              bounds.height >= minVisibleSize else { return [] }

        // Pre-allocate the output array to avoid repeated reallocations as the
        // recursive traversal appends children.  The estimate caps at 200k to
        // avoid over-allocating on huge drives; the array will grow beyond that
        // gracefully if needed.
        var result = [LayoutRect]()
        result.reserveCapacity(min(estimateNodeCount(node), 200_000))

        layoutInto(result: &result, node: node, bounds: bounds, depth: depth)
        return result
    }

    /// Recursive implementation that appends into a pre-allocated array.
    private func layoutInto(result: inout [LayoutRect], node: FileNode, bounds: CGRect, depth: Int) {
        guard node.totalSize > 0,
              bounds.width  >= minVisibleSize,
              bounds.height >= minVisibleSize else { return }

        result.append(LayoutRect(rect: bounds, node: node, depth: depth))

        // Apply optional filter to children (hidden-files toggle, etc.).
        let visibleChildren = nodeFilter.map { f in node.children.filter(f) } ?? node.children
        guard node.isDirectory, !visibleChildren.isEmpty else { return }

        // Children are already sorted largest-first (by DiskScanner.sortChildren).
        let areas = normalizedAreas(for: visibleChildren, totalArea: bounds.width * bounds.height)
        let childRects = squarify(areas: areas, in: bounds)

        for (child, childRect) in zip(visibleChildren, childRects) {
            layoutInto(result: &result, node: child, bounds: childRect, depth: depth + 1)
        }
    }

    /// Shallow estimate of visible node count — just enough to pick a reasonable
    /// `reserveCapacity`.  Walks two levels deep (O(N²) is fine for 2 levels).
    private func estimateNodeCount(_ node: FileNode) -> Int {
        guard node.isDirectory else { return 1 }
        let children = nodeFilter.map { f in node.children.filter(f) } ?? node.children
        return 1 + children.reduce(0) { sum, child in
            sum + 1 + (child.isDirectory ? child.children.count : 0)
        }
    }

    // MARK: - Squarified layout (internal — accessible from tests via @testable import)

    /// Returns one `CGRect` per element of `areas`, laid out squarified inside `rect`.
    /// Input areas must already be normalised to sum to `rect.width × rect.height`.
    func squarify(areas: [CGFloat], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: areas.count)
        guard !areas.isEmpty, rect.width > 0, rect.height > 0 else { return result }

        var remainingRect = rect
        var i = 0

        while i < areas.count {
            // w = length of the current strip (shorter side of remaining rect).
            let w = min(remainingRect.width, remainingRect.height)
            var row = [CGFloat]()
            var j = i

            // Greedily add items to the current row while aspect ratio improves.
            while j < areas.count {
                let next = areas[j]
                if row.isEmpty || worstAspect(row: row, w: w) >= worstAspect(row: row + [next], w: w) {
                    row.append(next)
                    j += 1
                } else {
                    break
                }
            }

            // Flush the row and shrink the remaining rect.
            remainingRect = placeRow(areas: row, startIndex: i, in: remainingRect, result: &result)
            i = j
        }

        return result
    }

    /// Worst aspect ratio for a candidate row using the squarified formula:
    ///   `worst = max(w² × max(row) / s², s² / (w² × min(row)))`
    /// where `s = sum(row)` and `w` is the strip length (shorter rect side).
    func worstAspect(row: [CGFloat], w: CGFloat) -> CGFloat {
        guard !row.isEmpty, w > 0 else { return .greatestFiniteMagnitude }
        let s = row.reduce(0, +)
        guard s > 0 else { return .greatestFiniteMagnitude }
        let maxA = row.max()!
        let minA = row.min()!
        let w2 = w * w
        let s2 = s * s
        return max(w2 * maxA / s2, s2 / (w2 * minA))
    }

    // MARK: - Private helpers

    /// Scale children sizes so their areas sum to `totalArea`.
    private func normalizedAreas(for children: [FileNode], totalArea: CGFloat) -> [CGFloat] {
        let totalSize = children.reduce(CGFloat(0)) { $0 + CGFloat($1.totalSize) }
        guard totalSize > 0 else { return Array(repeating: 0, count: children.count) }
        return children.map { CGFloat($0.totalSize) / totalSize * totalArea }
    }

    /// Place `areas` as a single strip inside `rect`, writing results into `result`
    /// starting at `startIndex`. Returns the rect with the strip removed.
    @discardableResult
    private func placeRow(
        areas: [CGFloat],
        startIndex: Int,
        in rect: CGRect,
        result: inout [CGRect]
    ) -> CGRect {
        let total = areas.reduce(0, +)
        guard total > 0 else { return rect }

        if rect.width >= rect.height {
            // Landscape → vertical strip: items stacked top-to-bottom, strip consumes from left.
            let stripWidth = total / rect.height
            var y = rect.minY
            for (i, area) in areas.enumerated() {
                let itemHeight = area / stripWidth
                result[startIndex + i] = CGRect(
                    x: rect.minX, y: y,
                    width: stripWidth, height: itemHeight
                )
                y += itemHeight
            }
            return CGRect(
                x: rect.minX + stripWidth, y: rect.minY,
                width: max(0, rect.width - stripWidth), height: rect.height
            )
        } else {
            // Portrait → horizontal strip: items laid left-to-right, strip consumes from top.
            let stripHeight = total / rect.width
            var x = rect.minX
            for (i, area) in areas.enumerated() {
                let itemWidth = area / stripHeight
                result[startIndex + i] = CGRect(
                    x: x, y: rect.minY,
                    width: itemWidth, height: stripHeight
                )
                x += itemWidth
            }
            return CGRect(
                x: rect.minX, y: rect.minY + stripHeight,
                width: rect.width, height: max(0, rect.height - stripHeight)
            )
        }
    }
}
