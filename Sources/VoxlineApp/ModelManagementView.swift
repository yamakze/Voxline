import SwiftUI
import VoxlineCore

public struct ModelManagementView: View {
    @State private var modelManager = ModelManager.shared

    public init() {}

    private var storageSegments: [StorageBreakdownBar.Segment] {
        let colors: [Color] = [.blue, .teal, .purple, .indigo, .orange]
        var segs: [StorageBreakdownBar.Segment] = []
        for (idx, model) in ModelManager.availableModels.enumerated() {
            let status = modelManager.status(for: model.id)
            if case .downloaded(_, let bytes) = status {
                segs.append(StorageBreakdownBar.Segment(
                    title: model.name,
                    byteCount: bytes,
                    color: colors[idx % colors.count]
                ))
            }
        }
        return segs
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("转写模型")
                        .font(.largeTitle.bold())
                    Spacer()
                }

                // macOS System Settings: Storage Breakdown Bar
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("模型储存空间", systemImage: "internaldrive")
                            .font(.headline)
                        Spacer()
                        let totalBytes = modelManager.totalDiskUsage()
                        let mb = Double(totalBytes) / 1_048_576.0
                        Text(mb >= 1024 ? String(format: "已用 %.2f GB", mb / 1024.0) : String(format: "已用 %.0f MB", mb))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }

                    StorageBreakdownBar(
                        totalDiskBytes: max(modelManager.totalDiskUsage() + 2_000_000_000, 10_000_000_000), // proportional scale
                        segments: storageSegments
                    )
                }
                .padding(18)
                .liquidGlassSurface()

                // Models List in Inset Grouped Cards
                VStack(alignment: .leading, spacing: 12) {
                    Text("可用模型库")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        ForEach(ModelManager.availableModels) { model in
                            modelCard(model: model)
                        }
                    }
                }
            }
            .padding(28)
        }
        .onAppear {
            modelManager.refreshAll()
        }
    }

    @ViewBuilder
    private func modelCard(model: WhisperModelDescriptor) -> some View {
        let status = modelManager.status(for: model.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                // Model Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(model.isBaseline ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(model.isBaseline ? .blue : .primary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.headline)

                        if model.isBaseline {
                            Text("官方推荐基准")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15), in: .capsule)
                                .foregroundStyle(.blue)
                        }

                        Spacer()

                        statusBadge(status: status)
                    }

                    Text(model.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Text(String(format: "预估大小：%.0f MB", model.expectedSizeMB))
                        Text("标识符：\(model.id)")
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
            }

            // Downloading progress bar
            if case .downloading(let progress) = status {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                    Text(String(format: "正在下载 CoreML 模型权重… %.0f%%", progress * 100))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()

            // Action row
            HStack {
                Spacer()
                switch status {
                case .notDownloaded:
                    Button("下载此模型", systemImage: "arrow.down.circle.fill") {
                        modelManager.download(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .downloading:
                    Button("取消下载", systemImage: "xmark.circle") {
                        modelManager.cancelDownload(modelID: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .downloaded:
                    Button("从本地移除", systemImage: "trash") {
                        modelManager.delete(modelID: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)

                case .failed(let reason):
                    Text("下载失败：\(reason)").font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("重新下载", systemImage: "arrow.clockwise") {
                        modelManager.download(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .corrupted(let reason):
                    Text("损坏：\(reason)").font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("重新下载", systemImage: "arrow.clockwise") {
                        modelManager.download(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .loading:
                    ProgressView().controlSize(.mini)
                    Text("加载中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .liquidGlassSurface()
    }

    @ViewBuilder
    private func statusBadge(status: ModelStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .downloaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status.label).foregroundStyle(.green)
            case .downloading:
                ProgressView().controlSize(.mini)
                Text(status.label).foregroundStyle(.blue)
            case .notDownloaded:
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text("未下载").foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.mini)
                Text("加载中").foregroundStyle(.blue)
            case .failed, .corrupted:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("异常").foregroundStyle(.red)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.1), in: .capsule)
    }
}
