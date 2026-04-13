import SwiftUI
import DiskMapper

/// SwiftUI Canvas-based treemap renderer.
///
/// Single-pass `Canvas` drawing — no per-cell views. Handles hundreds of
/// thousands of rects without frame-rate issues.
///
/// Interactions:
/// - Hover: highlights deepest rect under cursor; synced to sidebar.
/// - Single tap directory: drills down. Single tap file: toggles selection.
/// - Double-tap: reveals item in Finder.
/// - Right-click: context menu (reveal, copy path, move to trash).
/// - Breadcrumb: navigate back to an ancestor.
struct TreemapView: View {

    @ObservedObject var viewModel: TreemapViewModel

    @State private var trashTarget: FileNode?
    @State private var showingTrashDialog = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.navigationStack.isEmpty {
                BreadcrumbView(
                    stack: viewModel.breadcrumbPath,
                    onSelect: { viewModel.navigate(to: $0) }
                )
                .background(.bar)
                Divider()
            }

            GeometryReader { proxy in
                Canvas { ctx, size in
                    render(context: &ctx, size: size)
                }
                .help(tooltipText)
                // Hover → highlight in canvas + sidebar
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let loc): viewModel.hoveredID = viewModel.node(at: loc)?.id
                    case .ended:           viewModel.hoveredID = nil
                    }
                }
                // Double-tap → reveal in Finder
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    if let lr = viewModel.node(at: location) {
                        FinderActions.reveal(lr.node)
                    }
                }
                // Single-tap → drill down (dir) or toggle selection (file)
                .onTapGesture(coordinateSpace: .local) { location in
                    viewModel.handleTap(at: location)
                }
                // Right-click context menu (targets the hovered node)
                .contextMenu {
                    if let node = viewModel.hoveredNode {
                        contextMenuItems(for: node)
                    }
                }
                .onAppear { viewModel.scheduleLayout(size: proxy.size) }
                .onChange(of: proxy.size) { viewModel.scheduleLayout(size: $0) }
            }
        }
        .confirmationDialog(
            "Move to Trash?",
            isPresented: $showingTrashDialog,
            titleVisibility: .visible
        ) {
            Button("Move \u{201C}\(trashTarget?.name ?? "")\u{201D} to Trash", role: .destructive) {
                if let node = trashTarget { FinderActions.moveToTrash(node) }
                trashTarget = nil
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: {
            Text("This action can be undone from the Trash.")
        }
    }

    // MARK: - Tooltip

    private var tooltipText: String {
        guard let node = viewModel.hoveredNode else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: node.totalSize, countStyle: .file)
        return "\(node.path)\n\(size)"
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenuItems(for node: FileNode) -> some View {
        Button("Reveal in Finder") { FinderActions.reveal(node) }
        Button("Copy Path")        { FinderActions.copyPath(node) }
        Divider()
        Button("Move to Trash…", role: .destructive) {
            trashTarget = node
            showingTrashDialog = true
        }
    }

    // MARK: - Canvas rendering

    private func render(context: inout GraphicsContext, size: CGSize) {
        let rects          = viewModel.layoutRects
        let hoveredID      = viewModel.hoveredID
        let selectedID     = viewModel.selectedID
        let theme          = viewModel.colorTheme
        let searchMatchIDs = viewModel.searchMatchIDs
        let rootSize       = viewModel.displayRoot?.totalSize ?? 1

        // ── Background ──────────────────────────────────────────────────────
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(white: 0.10))
        )

        guard !rects.isEmpty else {
            let label = Text("Computing layout…")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        // ── File fills ──────────────────────────────────────────────────────
        for lr in rects where !lr.node.isDirectory {
            let sizeRatio = rootSize > 0
                ? log10(Double(lr.node.totalSize) + 1) / log10(Double(rootSize) + 1)
                : 0
            context.fill(
                Path(lr.rect),
                with: .color(FileKindColor.color(for: lr.node.kind, theme: theme, sizeRatio: sizeRatio))
            )
        }

        // ── Cell borders ────────────────────────────────────────────────────
        for lr in rects {
            let (color, width): (Color, CGFloat) = lr.node.isDirectory
                ? (.white.opacity(0.18), 1.0)
                : (.black.opacity(0.30), 0.5)
            context.stroke(Path(lr.rect), with: .color(color), lineWidth: width)
        }

        // ── Text labels ─────────────────────────────────────────────────────
        for lr in rects where !lr.node.isDirectory {
            guard lr.rect.width > 40, lr.rect.height > 14 else { continue }
            let fontSize = min(11, lr.rect.height * 0.35).rounded()
            let label = Text(lr.node.name)
                .font(.system(size: max(8, fontSize), weight: .medium))
                .foregroundColor(.white)
            context.draw(label, in: lr.rect.insetBy(dx: 4, dy: 2))
        }

        // ── Selection highlight (accent, persistent) ─────────────────────────
        if let id = selectedID, id != hoveredID,
           let lr = rects.first(where: { $0.id == id }) {
            context.stroke(
                Path(lr.rect.insetBy(dx: 1, dy: 1)),
                with: .color(Color.accentColor.opacity(0.9)),
                lineWidth: 2
            )
        }

        // ── Search match highlight (yellow ring) ─────────────────────────────
        if !searchMatchIDs.isEmpty {
            for lr in rects where searchMatchIDs.contains(lr.id) {
                context.stroke(
                    Path(lr.rect.insetBy(dx: 2, dy: 2)),
                    with: .color(Color.yellow.opacity(0.85)),
                    lineWidth: 2
                )
            }
        }

        // ── Hover highlight (white, follows cursor) ─────────────────────────
        if let id = hoveredID, let lr = rects.first(where: { $0.id == id }) {
            context.stroke(
                Path(lr.rect),
                with: .color(.white.opacity(0.35)),
                lineWidth: 4
            )
            context.stroke(
                Path(lr.rect.insetBy(dx: 1, dy: 1)),
                with: .color(.white),
                lineWidth: 2
            )
        }
    }
}
