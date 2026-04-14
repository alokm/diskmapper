import SwiftUI
import DiskMapper

/// Outline-style list panel showing the current directory's contents.
///
/// - Hover over a row → sets `viewModel.hoveredID`, highlighting the rect in the treemap.
/// - Click a file row → sets `viewModel.selectedID` (shown in the status bar).
/// - Click a directory row → drills down (same as tapping in the treemap).
/// - Always sorted by size, largest first.
/// - Search field: filters rows and highlights matching cells in the treemap.
struct NavigatorSidebar: View {

    @ObservedObject var viewModel: TreemapViewModel
    @State private var listSelection: String?
    @State private var trashTarget: FileNode?
    @State private var showingTrashDialog = false

    /// Cached result of the sort + filter pass.  Recomputed only when one of
    /// the four inputs changes: displayRoot, sortOrder, showHiddenFiles, searchText.
    @State private var filteredChildren: [FileNode] = []

    // MARK: - Helpers

    private var displayRoot: FileNode? { viewModel.displayRoot }

    // MARK: - Filter computation

    private func recomputeFilteredChildren() {
        guard let root = displayRoot else { filteredChildren = []; return }

        // Always sorted largest-first (DiskScanner pre-sorts the tree this way).
        var children = root.children

        if !viewModel.showHiddenFiles {
            children = children.filter { !$0.name.hasPrefix(".") }
        }
        let q = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            children = children.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }

        filteredChildren = children
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 220)
        .onAppear { recomputeFilteredChildren() }
        .onChange(of: viewModel.displayRoot?.id) { _ in recomputeFilteredChildren() }
        .onChange(of: viewModel.showHiddenFiles) { _ in recomputeFilteredChildren() }
        .onChange(of: viewModel.searchText)      { _ in recomputeFilteredChildren() }
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
        // Sidebar row selected → tell the viewModel
        .onChange(of: listSelection) { id in
            guard let id, let node = filteredChildren.first(where: { $0.id == id }) else {
                return
            }
            viewModel.handleNavigate(to: node)
        }
        // displayRoot changed (drill-down or back) → clear stale list selection
        .onChange(of: viewModel.displayRoot?.id) { _ in
            listSelection = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !viewModel.navigationStack.isEmpty {
                    Button { viewModel.navigateBack() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Go up one level (⌘[)")
                }

                Image(systemName: displayRoot?.isDirectory == true ? "folder.fill" : "house")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hue: 0.11, saturation: 0.72, brightness: 0.85))  // amber

                Text(displayRoot?.name ?? "Navigator")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let root = displayRoot, !root.children.isEmpty {
                    Text("\(filteredChildren.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // Search field — visible once a folder has been scanned
            if displayRoot != nil {
                searchField
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $viewModel.searchText)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if displayRoot == nil {
            // No scan yet
            VStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Scan a folder to\nbrowse its contents")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredChildren.isEmpty {
            let message = viewModel.searchText.isEmpty ? "Empty folder" : "No matches"
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredChildren, id: \.id, selection: $listSelection) { node in
                FileRowView(
                    node: node,
                    parentTotalSize: displayRoot?.totalSize ?? 1
                )
                .onHover { hovering in
                    viewModel.hoveredID = hovering ? node.id : nil
                }
                .contextMenu {
                    Button("Reveal in Finder") { FinderActions.reveal(node) }
                    Button("Copy Path")        { FinderActions.copyPath(node) }
                    Divider()
                    Button("Move to Trash…", role: .destructive) {
                        trashTarget = node
                        showingTrashDialog = true
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}
