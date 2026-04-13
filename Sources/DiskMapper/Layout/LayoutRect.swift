import CoreGraphics

/// One output rectangle from the treemap layout engine.
///
/// The full layout output is a flat array of `LayoutRect` values — one per
/// visible node (file or directory). Directory rects contain their children's
/// rects, so renderers should draw parents before children.
public struct LayoutRect: Identifiable, Sendable {

    /// Stable identity delegated to the underlying node's path.
    public var id: String { node.id }

    /// Position and size in the coordinate space passed to `TreemapLayout.layout(node:in:)`.
    public let rect: CGRect

    /// The file or directory this rectangle represents.
    public let node: FileNode

    /// Nesting depth (0 = root passed to the layout call, 1 = its direct children, …).
    public let depth: Int
}
