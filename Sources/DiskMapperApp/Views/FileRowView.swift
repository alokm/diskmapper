import SwiftUI
import DiskMapper

/// A single row in the navigator sidebar showing icon, name, size bar, size, and date.
struct FileRowView: View {

    let node: FileNode
    let parentTotalSize: Int64

    private var proportion: Double {
        guard parentTotalSize > 0 else { return 0 }
        return min(1.0, Double(node.totalSize) / Double(parentTotalSize))
    }

    var body: some View {
        HStack(spacing: 8) {
            // Kind icon
            Image(systemName: FileKindColor.iconName(for: node.kind))
                .font(.system(size: 13))
                .foregroundStyle(FileKindColor.color(for: node.kind))
                .frame(width: 16)

            // Name + size bar + date
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Proportional size bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(FileKindColor.color(for: node.kind).opacity(0.70))
                            .frame(width: geo.size.width * proportion)
                    }
                }
                .frame(height: 3)

                // Modification date (files only, when available)
                if !node.isDirectory, let date = node.modifiedDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            // Size label
            Text(ByteCountFormatter.string(fromByteCount: node.totalSize, countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
