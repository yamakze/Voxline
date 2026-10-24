import SwiftUI

// MARK: - Storage usage
public struct StorageSegment: Identifiable {
    public let id = UUID()
    public let title: String
    public let byteCount: Int64
    public let color: Color

    public init(title: String, byteCount: Int64, color: Color) {
        self.title = title
        self.byteCount = byteCount
        self.color = color
    }
}

public struct StorageBreakdownBar<Trailing: View>: View {
    public typealias Segment = StorageSegment

    public let totalDiskBytes: Int64
    public let segments: [StorageSegment]
    private let trailing: Trailing

    public init(totalDiskBytes: Int64, segments: [StorageSegment], @ViewBuilder trailing: () -> Trailing) {
        self.totalDiskBytes = totalDiskBytes
        self.segments = segments
        self.trailing = trailing()
    }

    public init(totalDiskBytes: Int64, segments: [StorageSegment]) where Trailing == EmptyView {
        self.totalDiskBytes = totalDiskBytes
        self.segments = segments
        self.trailing = EmptyView()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Segmented Bar
            GeometryReader { geometry in
                let total = max(Double(totalDiskBytes), 1.0)
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let width = max(Double(segment.byteCount) / total * geometry.size.width, segment.byteCount > 0 ? 4.0 : 0.0)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [segment.color, segment.color.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: width)
                    }
                    // Free space
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())

            // Legend
            HStack(alignment: .center, spacing: 16) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title).font(.caption).foregroundStyle(.primary)
                        let mb = Double(segment.byteCount) / 1_000_000.0
                        Text(mb >= 1000 ? String(format: "%.1f GB", mb / 1000.0) : String(format: "%.0f MB", mb))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing
            }
        }
    }
}

// MARK: - Password visibility
public struct PasswordVisibilityField: View {
    public let title: String
    @Binding public var text: String
    private enum Field { case plain, secure }
    @FocusState private var focusedField: Field?
    @State private var isRevealed: Bool = false

    public init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text).focused($focusedField, equals: .plain)
                } else {
                    SecureField(title, text: $text).focused($focusedField, equals: .secure)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isRevealed.toggle()
                focusedField = isRevealed ? .plain : .secure
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? String(localized: "隐藏密钥", bundle: appLocalizationBundle) : String(localized: "显示明文密钥", bundle: appLocalizationBundle))
        }
    }
}
