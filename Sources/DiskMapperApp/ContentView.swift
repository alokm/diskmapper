import SwiftUI
import UniformTypeIdentifiers
import DiskMapper

struct ContentView: View {

    @StateObject private var appState = AppState()
    @StateObject private var treemapViewModel = TreemapViewModel()
    @State private var showingPicker = false
    @State private var sidebarWidth: CGFloat = 280

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                NavigatorSidebar(viewModel: treemapViewModel)
                    .frame(width: sidebarWidth)
                sidebarHandle
                mainContent
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: appState.rootNode?.id) { _ in
            if let root = appState.rootNode { treemapViewModel.setRoot(root) }
        }
        // Cmd+[ → navigate back (standard macOS browser convention)
        .background {
            Button("Back") { treemapViewModel.navigateBack() }
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
        }
        .fileImporter(
            isPresented: $showingPicker,
            allowedContentTypes: [UTType.folder]
        ) { result in
            switch result {
            case .success(let url):  appState.beginScan(url: url)
            case .failure(let err):  appState.errorMessage = err.localizedDescription
            }
        }
    }

    // MARK: - Resizable sidebar divider

    private var sidebarHandle: some View {
        ZStack {
            Color(nsColor: .separatorColor).frame(width: 1)
            Color.clear
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    sidebarWidth = max(160, min(520, sidebarWidth + value.translation.width))
                }
        )
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { showingPicker = true } label: {
                Label("Choose Folder", systemImage: "folder")
            }
            .disabled(appState.isScanning)

            // Rescan button — only when a previous scan exists
            if appState.lastScannedURL != nil, !appState.isScanning {
                Button { appState.rescan() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            if appState.isScanning {
                Button(role: .cancel) { appState.cancelScan() } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }

            Divider().frame(height: 16)

            // Hidden-files toggle
            if appState.rootNode != nil {
                Toggle(isOn: $treemapViewModel.showHiddenFiles) {
                    Image(systemName: treemapViewModel.showHiddenFiles
                          ? "eye.fill" : "eye.slash")
                        .font(.system(size: 13))
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help(treemapViewModel.showHiddenFiles ? "Hide hidden files" : "Show hidden files")
                .onChange(of: treemapViewModel.showHiddenFiles) { _ in
                    // Re-run layout from the current display root so the toggle
                    // takes effect without resetting drill-down position.
                    treemapViewModel.rescheduleLayout()
                }

                Divider().frame(height: 16)
            }

            // Scan progress / current folder info
            if appState.isScanning {
                if let fraction = appState.scanProgress {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                        .help("\(Int(fraction * 100))% of volume scanned")
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                Text(progressLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let root = appState.rootNode {
                Text(root.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: root.totalSize, countStyle: .file))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !appState.isScanning { legend }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var progressLabel: String {
        let count = appState.scannedCount
        let rate  = appState.itemsPerSecond
        let name  = appState.currentName.isEmpty ? "" : "  \(appState.currentName)"
        let rateStr = rate > 0 ? "  ·  \(Int(rate).formatted())/s" : ""
        return "\(count.formatted()) items\(rateStr)\(name)"
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 8) {
            ForEach(FileKindColor.legend, id: \.kind) { entry in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(FileKindColor.color(for: entry.kind))
                        .frame(width: 10, height: 10)
                    Text(entry.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Main content (treemap area)

    @ViewBuilder
    private var mainContent: some View {
        if appState.isScanning {
            scanningPlaceholder
        } else if treemapViewModel.displayRoot == nil {
            emptyState
        } else {
            TreemapView(viewModel: treemapViewModel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Choose a folder to visualise disk usage")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Choose Folder…") { showingPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 16) {
            if let fraction = appState.scanProgress {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 28, weight: .thin, design: .rounded))
                    .foregroundStyle(.primary)
            } else {
                ProgressView().scaleEffect(1.5)
            }
            Text("Scanning…")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(progressLabel)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 4) {
            if let error = appState.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                statusContent
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusContent: some View {
        if let node = treemapViewModel.hoveredNode ?? treemapViewModel.selectedNode {
            // Icon
            Image(systemName: FileKindColor.iconName(for: node.kind))
                .font(.system(size: 10))
                .foregroundStyle(FileKindColor.color(for: node.kind))
            // Name
            Text(node.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·").foregroundStyle(.tertiary)
            // Kind
            Text(node.isDirectory ? "Folder" : node.kind.rawValue.capitalized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            // Size
            Text(ByteCountFormatter.string(fromByteCount: node.totalSize, countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            // Date
            if !node.isDirectory, let date = node.modifiedDate {
                Text("·").foregroundStyle(.tertiary)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else {
            let root = treemapViewModel.displayRoot
            Text(root?.path ?? "No folder selected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let root {
                Text("·").foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: root.totalSize, countStyle: .file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
