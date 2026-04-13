import SwiftUI
import DiskMapper

/// Shared display state for both the treemap canvas and the navigator sidebar.
///
/// Lives on the `@MainActor`. Expensive layout work is offloaded to a
/// `Task.detached` and results are posted back to the main actor.
@MainActor
final class TreemapViewModel: ObservableObject {

    // MARK: - Published state

    /// The subtree currently rendered by the treemap (nil before first scan).
    @Published var displayRoot: FileNode?
    @Published var layoutRects: [LayoutRect] = []
    /// ID of the node currently under the cursor (set by treemap hover or sidebar hover).
    @Published var hoveredID: String?
    /// ID of the node explicitly selected (set by sidebar click or treemap tap on a file).
    @Published var selectedID: String?
    @Published var navigationStack: [FileNode] = []

    // MARK: - Phase 6: filter / theme / search

    /// How treemap cells are coloured.
    @Published var colorTheme: ColorTheme = .byKind
    /// Live text used to filter sidebar rows and highlight treemap cells.
    @Published var searchText: String = ""
    /// When false (default), entries whose names start with "." are hidden.
    @Published var showHiddenFiles: Bool = false

    // MARK: - Private

    private var layoutTask: Task<Void, Never>?
    private var canvasSize: CGSize = .zero

    // MARK: - Init

    init() {}

    // MARK: - Computed

    /// Full path from root to `displayRoot` — used by the breadcrumb bar.
    var breadcrumbPath: [FileNode] {
        guard let root = displayRoot else { return [] }
        return navigationStack + [root]
    }

    /// The `FileNode` currently under the cursor, if any.
    var hoveredNode: FileNode? {
        guard let id = hoveredID else { return nil }
        return layoutRects.first { $0.id == id }?.node
    }

    /// The explicitly selected `FileNode`, if visible in the current layout.
    var selectedNode: FileNode? {
        guard let id = selectedID else { return nil }
        return layoutRects.first { $0.id == id }?.node
    }

    /// IDs of layout rects whose node names match the current search text.
    var searchMatchIDs: Set<String> {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Set(layoutRects.compactMap { lr in
            lr.node.name.localizedCaseInsensitiveContains(q) ? lr.id : nil
        })
    }

    // MARK: - Root management

    /// Called after a new scan completes. Resets navigation and triggers layout.
    func setRoot(_ root: FileNode) {
        navigationStack = []
        displayRoot = root
        selectedID = nil
        searchText = ""
        layoutRects = []
        scheduleLayout(size: canvasSize)
    }

    // MARK: - Layout

    /// Re-run layout using the last known canvas size (e.g. after toggling hidden files).
    func rescheduleLayout() { scheduleLayout(size: canvasSize) }

    func scheduleLayout(size: CGSize) {
        canvasSize = size
        layoutTask?.cancel()
        guard let root = displayRoot, size.width > 0, size.height > 0 else { return }

        let bounds      = CGRect(origin: .zero, size: size)
        // Build the filter and layout engine before the Task so the closure
        // doesn't capture a function-typed local (which confuses type inference).
        var filterFn: (@Sendable (FileNode) -> Bool)? = nil
        if !showHiddenFiles {
            filterFn = { (n: FileNode) in !n.name.hasPrefix(".") }
        }
        let engine = TreemapLayout(nodeFilter: filterFn)

        layoutTask = Task {
            let rects = await Task.detached(priority: .userInitiated) {
                engine.layout(node: root, in: bounds)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                self.layoutRects = rects
            }
        }
    }

    // MARK: - Hit testing

    func node(at point: CGPoint) -> LayoutRect? {
        layoutRects
            .filter { $0.rect.contains(point) }
            .max { $0.depth < $1.depth }
    }

    // MARK: - Navigation

    /// Treemap single-tap: drill into a directory; toggle selection on files.
    func handleTap(at point: CGPoint) {
        guard let lr = node(at: point) else { return }
        if lr.node.isDirectory, lr.node.id != displayRoot?.id {
            drillDown(to: lr.node)
        } else if !lr.node.isDirectory {
            selectedID = (selectedID == lr.node.id) ? nil : lr.node.id
        }
    }

    /// Sidebar click: drill into a directory, or select a file.
    func handleNavigate(to node: FileNode) {
        if node.isDirectory, node.id != displayRoot?.id {
            drillDown(to: node)
        } else {
            selectedID = node.id
        }
    }

    /// Breadcrumb tap: pop the nav stack back to the tapped ancestor.
    func navigate(to target: FileNode) {
        guard target.id != displayRoot?.id else { return }
        guard let idx = navigationStack.firstIndex(where: { $0.id == target.id }) else { return }
        displayRoot = target
        navigationStack = Array(navigationStack.prefix(idx))
        selectedID = nil
        layoutRects = []
        scheduleLayout(size: canvasSize)
    }

    func navigateBack() {
        guard let last = navigationStack.popLast() else { return }
        displayRoot = last
        selectedID = nil
        layoutRects = []
        scheduleLayout(size: canvasSize)
    }

    // MARK: - Private

    private func drillDown(to node: FileNode) {
        if let current = displayRoot { navigationStack.append(current) }
        displayRoot = node
        selectedID = nil
        layoutRects = []
        scheduleLayout(size: canvasSize)
    }
}
