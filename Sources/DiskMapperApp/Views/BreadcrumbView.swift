import SwiftUI
import DiskMapper

/// A horizontal breadcrumb bar showing the current navigation path.
/// Tapping any segment navigates back to that ancestor.
struct BreadcrumbView: View {

    let stack: [FileNode]           // all nodes from root through current displayRoot
    let onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(stack.enumerated()), id: \.element.id) { idx, node in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        onSelect(node)
                    } label: {
                        Text(node.name)
                            .font(.system(size: 12, weight: idx == stack.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == stack.count - 1 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(idx == stack.count - 1) // current segment is not tappable
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }
}
