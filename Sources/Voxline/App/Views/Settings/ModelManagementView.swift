import VoxlineWhisperKit
import SwiftUI
#if os(macOS)
import AppKit
#endif
import VoxlineCore

public struct ModelManagementView: View {
    @State private var modelManager = ModelManager.shared

    public init() {}

    private var storageSegments: [StorageSegment] {
        let colors: [Color] = [.blue, .teal, .purple, .indigo, .orange]
        var segs: [StorageSegment] = []
        for (idx, model) in ModelManager.availableModels.enumerated() {
            if let bytes = modelManager.diskUsage[model.id], bytes > 0 {
                segs.append(StorageSegment(
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
                // Storage Breakdown Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(String(localized: "模型储存空间", bundle: appLocalizationBundle), systemImage: "internaldrive")
                            .font(.headline)
                        Spacer()
                        let totalBytes = modelManager.totalDiskUsage()
                        let mb = Double(totalBytes) / 1_000_000.0
                        Text(mb >= 1000 ? String(format: String(localized: "已用 %.2f GB", bundle: appLocalizationBundle), locale: .current, mb / 1000.0) : String(format: String(localized: "已用 %.0f MB", bundle: appLocalizationBundle), locale: .current, mb))
                            .font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }

                    StorageBreakdownBar(
                        totalDiskBytes: max(modelManager.totalDiskUsage(), 1),
                        segments: storageSegments
                    ) {
                        #if os(macOS)
                        Button {
                            if let dir = modelManager.modelDirectories.values.first ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("huggingface/models") {
                                NSWorkspace.shared.open(dir)
                            }
                        } label: {
                            Label(String(localized: "打开目录", bundle: appLocalizationBundle), systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(String(localized: "在访达中打开模型存储目录", bundle: appLocalizationBundle))
                        #endif
                    }

                    if let error = modelManager.storageError {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(16)
                .liquidGlassSurface(cornerRadius: 12)

                // Models List
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "可用模型", bundle: appLocalizationBundle))
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        ForEach(ModelManager.availableModels) { model in
                            modelCard(model: model)
                        }
                    }
                }
            }
            .padding(24)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "模型管理", bundle: appLocalizationBundle))
        #endif
        .task {
            await modelManager.refreshAll()
        }
    }

    @ViewBuilder
    private func modelCard(model: WhisperModelDescriptor) -> some View {
        let status = modelManager.status(for: model.id)
        let usage = modelManager.diskUsage[model.id] ?? 0
        let modelError: String? = switch status {
        case .failed(let reason), .corrupted(let reason): reason
        default: nil
        }

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                // Model Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.isBaseline ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu")
                        .font(.system(size: 18))
                        .foregroundStyle(model.isBaseline ? .blue : .primary)
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.headline)

                        if model.isBaseline {
                            Text(String(localized: "默认推荐", bundle: appLocalizationBundle))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: .capsule)
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(model.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        if usage > 0 {
                            let mb = Double(usage) / 1_000_000.0
                            Text(String(format: String(localized: "已占 %.0f MB", bundle: appLocalizationBundle), locale: .current, mb))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(format: String(localized: "约 %.0f MB", bundle: appLocalizationBundle), locale: .current, model.expectedSizeMB))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                // Actions & Status
                HStack(spacing: 10) {
                    if modelManager.deletingModels.contains(model.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        statusBadge(status: status)
                    }

                    switch status {
                    case .notDownloaded, .cancelled:
                        Button(String(localized: "下载", bundle: appLocalizationBundle)) {
                            modelManager.download(modelID: model.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .downloading, .checking:
                        Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                            modelManager.cancelDownload(modelID: model.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    case .downloaded, .ready:
                        modelOptionsMenu(model: model, usage: usage)

                    case .failed, .corrupted:
                        if modelManager.deletionErrors[model.id] == nil {
                            Button(String(localized: "重新下载", bundle: appLocalizationBundle)) {
                                modelManager.download(modelID: model.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(modelManager.isOperating || modelManager.deletingModels.contains(model.id))
                        }

                        if usage > 0 {
                            modelOptionsMenu(model: model, usage: usage)
                        }

                    case .loading, .cancelling:
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(14)

            if let error = modelManager.deletionErrors[model.id] {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(String(localized: "重试删除", bundle: appLocalizationBundle), role: .destructive) {
                        Task { await modelManager.delete(modelID: model.id) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(modelManager.isOperating || modelManager.deletingModels.contains(model.id))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            } else if let reason = modelError {
                Text(reason).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }

            // Progress bar if downloading
            if case .downloading(let component, let progress) = status {
                VStack(spacing: 4) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(component)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .liquidGlassSurface(cornerRadius: 12)
    }

    @ViewBuilder
    private func modelOptionsMenu(model: WhisperModelDescriptor, usage: Int64) -> some View {
        Menu {
            #if os(macOS)
            if let directory = modelManager.modelDirectories[model.id], usage > 0 {
                Button {
                    NSWorkspace.shared.open(directory)
                } label: {
                    Label(String(localized: "在访达中显示", bundle: appLocalizationBundle), systemImage: "folder")
                }
            }
            #endif

            if usage > 0 {
                #if os(macOS)
                Divider()
                #endif
                Button(role: .destructive) {
                    Task { await modelManager.delete(modelID: model.id) }
                } label: {
                    Label(String(localized: "删除模型文件", bundle: appLocalizationBundle), systemImage: "trash")
                }
                .disabled(modelManager.isOperating || modelManager.deletingModels.contains(model.id))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statusBadge(status: ModelStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .ready, .downloaded:
                Circle().fill(modelManager.isOperating ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(String(localized: "已就绪", bundle: appLocalizationBundle))
                    .foregroundStyle(modelManager.isOperating ? .orange : .green)
            case .downloading, .checking:
                ProgressView().controlSize(.mini)
                Text(String(localized: "下载中", bundle: appLocalizationBundle)).foregroundStyle(.blue)
            case .notDownloaded:
                EmptyView()
            case .loading:
                ProgressView().controlSize(.mini)
                Text(String(localized: "准备中", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
            case .cancelling:
                ProgressView().controlSize(.mini)
                Text(String(localized: "正在取消", bundle: appLocalizationBundle)).foregroundStyle(.secondary)
            case .cancelled:
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text(String(localized: "已取消", bundle: appLocalizationBundle)).foregroundStyle(.orange)
            case .failed, .corrupted:
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text(String(localized: "异常", bundle: appLocalizationBundle)).foregroundStyle(.red)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, status == .notDownloaded ? 0 : 7)
        .padding(.vertical, status == .notDownloaded ? 0 : 3)
        .background(
            status == .notDownloaded ? Color.clear : Color.secondary.opacity(0.08),
            in: .capsule
        )
    }
}
