import SwiftUI
import VoxlineCore

public struct NativeControlSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
    }

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

public struct NativeGlassCapsuleSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.95), in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
        } else {
            content
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        }
    }
}

public struct NativeSubtitleOverlaySurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.black.opacity(0.88), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
        } else if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .background(Color.black.opacity(0.45), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                .background(Color.black.opacity(0.55), in: .rect(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

public extension View {
    func liquidGlassSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(NativeControlSurface(cornerRadius: cornerRadius))
    }

    func liquidGlassCapsule() -> some View {
        modifier(NativeGlassCapsuleSurface())
    }

    func subtitleOverlaySurface() -> some View {
        modifier(NativeSubtitleOverlaySurface())
    }
}

// MARK: - Task Status Badge
public struct TaskStatusBadge: View {
    public let status: ProcessingTaskStatus

    public init(status: ProcessingTaskStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(backgroundColor.opacity(0.15), in: .capsule)
        .foregroundStyle(foregroundColor)
    }

    private var iconName: String {
        switch status {
        case .draft: return "pencil.circle"
        case .queued: return "clock"
        case .needsReview: return "exclamationmark.triangle"
        case .running: return "arrow.triangle.2.circlepath.circle"
        case .interrupted: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .partiallyFailed: return "exclamationmark.circle"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "nosign"
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .draft: return .secondary
        case .queued: return .blue
        case .needsReview: return .orange
        case .running: return .blue
        case .interrupted: return .orange
        case .completed: return .green
        case .partiallyFailed: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .draft: return .secondary
        case .queued: return .blue
        case .needsReview: return .orange
        case .running: return .blue
        case .interrupted: return .orange
        case .completed: return .green
        case .partiallyFailed: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Media Status Badge
public struct MediaStatusBadge: View {
    public let status: TaskMediaStatus

    public init(status: TaskMediaStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(backgroundColor.opacity(0.15), in: .capsule)
        .foregroundStyle(foregroundColor)
    }

    private var iconName: String {
        switch status {
        case .pending: return "clock"
        case .needsReview: return "exclamationmark.triangle"
        case .running(let stage):
            switch stage {
            case .audioExtraction: return "waveform"
            case .transcription: return "text.bubble"
            case .translation: return "character.book.closed"
            }
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "nosign"
        case .interrupted: return "pause.circle"
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .pending: return .secondary
        case .needsReview: return .orange
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        case .interrupted: return .orange
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .pending: return .secondary
        case .needsReview: return .orange
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .interrupted: return .orange
        }
    }
}

// MARK: - Xcode Step Pipeline Badge (Build Tasks Pipeline)
public struct XcodeStepPipelineView: View {
    public let status: TaskMediaStatus
    public let hasTranslation: Bool

    public init(status: TaskMediaStatus, hasTranslation: Bool = true) {
        self.status = status
        self.hasTranslation = hasTranslation
    }

    private enum StepState {
        case completed, inProgress, waiting, failed, cancelled
    }

    public var body: some View {
        HStack(spacing: 4) {
            stepChip(title: "提取音频", state: extractionState)
            connectorLine(isActive: transcriptionState != .waiting)
            stepChip(title: "本地转写", state: transcriptionState)

            if hasTranslation {
                connectorLine(isActive: translationState != .waiting)
                stepChip(title: "字幕翻译", state: translationState)
            }

            connectorLine(isActive: isCompleted)
            stepChip(title: "就绪", state: isCompleted ? .completed : (isFailed ? .failed : (isCancelled ? .cancelled : .waiting)))
        }
        .font(.caption2)
    }

    private var extractionState: StepState {
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            return stage == .audioExtraction ? .inProgress : .completed
        case .completed, .needsReview: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            return stage == .audioExtraction ? .inProgress : .completed
        }
    }

    private var transcriptionState: StepState {
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            if stage == .audioExtraction { return .waiting }
            if stage == .transcription { return .inProgress }
            return .completed
        case .completed, .needsReview: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            if stage == .audioExtraction { return .waiting }
            if stage == .transcription { return .inProgress }
            return .completed
        }
    }

    private var translationState: StepState {
        switch status {
        case .pending: return .waiting
        case .running(let stage):
            return stage == .translation ? .inProgress : .waiting
        case .completed, .needsReview: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted(let stage):
            return stage == .translation ? .inProgress : .waiting
        }
    }

    private var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var isCancelled: Bool {
        if case .cancelled = status { return true }
        return false
    }

    @ViewBuilder
    private func stepChip(title: String, state: StepState) -> some View {
        HStack(spacing: 3) {
            switch state {
            case .completed:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
            case .inProgress:
                ProgressView().controlSize(.mini)
            case .waiting:
                Circle().fill(Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "minus").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            Text(title)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            state == .inProgress
                ? Color.accentColor.opacity(0.15)
                : (state == .completed ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)),
            in: .capsule
        )
        .foregroundStyle(state == .inProgress ? Color.accentColor : (state == .completed ? Color.primary : Color.secondary))
    }

    @ViewBuilder
    private func connectorLine(isActive: Bool) -> some View {
        Rectangle()
            .fill(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
            .frame(width: 8, height: 1.5)
    }
}

// MARK: - macOS System Settings Storage Breakdown Bar
public struct StorageBreakdownBar: View {
    public struct Segment: Identifiable {
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

    public let totalDiskBytes: Int64
    public let segments: [Segment]

    public init(totalDiskBytes: Int64, segments: [Segment]) {
        self.totalDiskBytes = totalDiskBytes
        self.segments = segments
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Segmented Bar
            GeometryReader { geometry in
                let total = max(Double(totalDiskBytes), 1.0)
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        let width = max(Double(segment.byteCount) / total * geometry.size.width, segment.byteCount > 0 ? 4.0 : 0.0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.color)
                            .frame(width: width)
                    }
                    // Free space
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Legend
            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.title).font(.caption).foregroundStyle(.primary)
                        let mb = Double(segment.byteCount) / 1_048_576.0
                        Text(mb >= 1024 ? String(format: "%.1f GB", mb / 1024.0) : String(format: "%.0f MB", mb))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - SecurePasswordField with Eye Toggle (macOS System Settings)
public struct PasswordVisibilityField: View {
    public let title: String
    @Binding public var text: String
    @State private var isRevealed: Bool = false

    public init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "隐藏密钥" : "显示明文密钥")
        }
    }
}
