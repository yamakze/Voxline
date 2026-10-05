import VoxlineWhisperKit
import SwiftUI
#if os(macOS)
import AppKit
#endif
import VoxlineCore

public struct ModelManagementView: View {
    @State private var modelManager = ModelManager.shared

    public init() {}

    private var storageSegments: [StorageBreakdownBar.Segment] {
        let colors: [Color] = [.blue, .teal, .purple, .indigo, .orange]
        var segs: [StorageBreakdownBar.Segment] = []
        for (idx, model) in ModelManager.availableModels.enumerated() {
            if let bytes = modelManager.diskUsage[model.id], bytes > 0 {
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
                // macOS System Settings: Storage Breakdown Bar
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("模型储存空间", systemImage: "internaldrive")
                            .font(.headline)
                        Spacer()
                        let totalBytes = modelManager.totalDiskUsage()
                        let mb = Double(totalBytes) / 1_000_000.0
                        Text(mb >= 1000 ? String(format: "已用 %.2f GB", mb / 1000.0) : String(format: "已用 %.0f MB", mb))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }

                    StorageBreakdownBar(
                        totalDiskBytes: max(modelManager.totalDiskUsage(), 1),
                        segments: storageSegments
                    )
                    Text("模型、分词器与下载缓存的本地文件占用")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = modelManager.storageError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
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
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) {
                Text("模型管理")
                    .font(.headline)
            }

            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
            #endif
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(macOS)
                Button {
                    if let dir = modelManager.modelDirectories.values.first ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("huggingface/models") {
                        NSWorkspace.shared.open(dir)
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .help("在访达中打开模型存储目录")

                #endif
                Button {
                    Task { await modelManager.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新检测与刷新模型状态")
            }
        }
        .navigationTitle("模型管理")
        .task {
            await modelManager.refreshAll()
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
                    Text(model.name)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if model.isBaseline {
                            Text("S001 基准")
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "预估大小：%.0f MB", model.expectedSizeMB))
                        Text("标识符：\(model.id)").textSelection(.enabled)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
            }

            // Downloading progress bar
            if case .downloading(let component, let progress) = status {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                    Text(String(format: "%@文件下载进度 %.0f%%", component, progress * 100))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let revision = modelManager.modelRevisions[model.id] {
                Text("固定版本：\(revision)").font(.caption2.monospaced()).textSelection(.enabled)
            }
            #if os(iOS)
            Text("加载占用设备内存。可用型号与处理速度以真机验证为准；下载完成不代表已加载。")
                .font(.caption).foregroundStyle(.secondary)
            #endif
            Divider()

            // Action row
            HStack {
                Spacer()
                switch status {
                case .notDownloaded, .cancelled:
                    Button("下载此模型", systemImage: "arrow.down.circle.fill") {
                        modelManager.download(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .downloading, .checking:
                    Button("取消下载", systemImage: "xmark.circle") {
                        modelManager.cancelDownload(modelID: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .downloaded:
                    Button("验证并加载", systemImage: "checkmark.circle") {
                        modelManager.load(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .ready:
                    Button("卸载模型", systemImage: "eject") {
                        Task { await modelManager.unload(modelID: model.id) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                case .failed(let reason), .corrupted(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button("重新下载", systemImage: "arrow.clockwise") {
                        modelManager.download(modelID: model.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .loading, .cancelling:
                    ProgressView().controlSize(.mini)
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                }
                switch status {
                case .downloaded, .cancelled, .failed, .corrupted:
                    if (modelManager.diskUsage[model.id] ?? 0) > 0 {
                        Button("从本地移除", systemImage: "trash") {
                            Task { await modelManager.delete(modelID: model.id) }
                        }
                        .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
                    }
                default: EmptyView()
                }
                #if os(macOS)
                if let directory = modelManager.modelDirectories[model.id],
                   (modelManager.diskUsage[model.id] ?? 0) > 0 {
                    Button("打开目录", systemImage: "folder") { NSWorkspace.shared.open(directory) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                #endif
            }
        }
        .padding(16)
        .liquidGlassSurface()
    }

    @ViewBuilder
    private func statusBadge(status: ModelStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status.label).foregroundStyle(.green)
            case .downloaded:
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(status.label).foregroundStyle(.secondary)
            case .downloading, .checking:
                ProgressView().controlSize(.mini)
                Text(status.label).foregroundStyle(.blue)
            case .notDownloaded:
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text("未下载").foregroundStyle(.secondary)
            case .loading, .cancelling:
                ProgressView().controlSize(.mini)
                Text(status.label).foregroundStyle(.blue)
            case .cancelled:
                Text(status.label).foregroundStyle(.secondary)
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
