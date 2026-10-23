import VoxlineWhisperKit
import SwiftUI
#if os(macOS)
import AppKit
#endif
import VoxlineCore

public struct ModelManagementView: View {
    @State private var modelManager = ModelManager.shared

    @State private var modelPendingDeletion: WhisperModelDescriptor?

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
                            if let dir = modelManager.modelDirectories.values.first?.deletingLastPathComponent() {
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
                            ModelCardRow(
                                model: model,
                                status: modelManager.status(for: model.id),
                                usage: modelManager.diskUsage[model.id] ?? 0,
                                directory: modelManager.modelDirectories[model.id],
                                isDeleting: modelManager.deletingModels.contains(model.id),
                                isOperating: modelManager.isOperating,
                                deletionError: modelManager.deletionErrors[model.id],
                                onDownload: {
                                    modelManager.download(modelID: model.id)
                                },
                                onCancel: {
                                    modelManager.cancelDownload(modelID: model.id)
                                },
                                onRequestDelete: {
                                    modelPendingDeletion = model
                                }
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
        #if os(iOS)
        .navigationTitle(String(localized: "模型管理", bundle: appLocalizationBundle))
        #endif
        #if os(macOS)
        .alert(
            String(localized: "删除模型文件", bundle: appLocalizationBundle),
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { target in
            Button(String(localized: "删除模型文件", bundle: appLocalizationBundle), role: .destructive) {
                let id = target.id
                Task { await modelManager.delete(modelID: id) }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
        } message: { target in
            let usage = modelManager.diskUsage[target.id] ?? 0
            let mb = Double(usage) / 1_000_000.0
            Text(String(format: String(localized: "确定要删除 %@ 吗？将释放约 %.0f MB 磁盘空间，后续使用需重新下载。", bundle: appLocalizationBundle), locale: .current, target.name, mb))
        }
        #else
        .confirmationDialog(
            String(localized: "删除模型文件", bundle: appLocalizationBundle),
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { target in
            Button(String(localized: "删除模型文件", bundle: appLocalizationBundle), role: .destructive) {
                let id = target.id
                Task { await modelManager.delete(modelID: id) }
            }
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
        } message: { target in
            let usage = modelManager.diskUsage[target.id] ?? 0
            let mb = Double(usage) / 1_000_000.0
            Text(String(format: String(localized: "确定要删除 %@ 吗？将释放约 %.0f MB 磁盘空间，后续使用需重新下载。", bundle: appLocalizationBundle), locale: .current, target.name, mb))
        }
        #endif
        .task {
            await modelManager.refreshAll()
        }
    }
}

// MARK: - Hover Border
private struct HoverBorder: View {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(isHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), lineWidth: 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

// MARK: - Model Card Row
private struct ModelCardRow: View {
    let model: WhisperModelDescriptor
    let status: ModelStatus
    let usage: Int64
    let directory: URL?
    let isDeleting: Bool
    let isOperating: Bool
    let deletionError: String?
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onRequestDelete: () -> Void

    private var modelError: String? {
        switch status {
        case .failed(let reason), .corrupted(let reason):
            return reason
        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                // Model Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            model.isBaseline
                                ? LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [Color.secondary.opacity(0.12), Color.secondary.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    model.isBaseline ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                    lineWidth: 0.8
                                )
                        )
                        .frame(width: 40, height: 40)
                    Image(systemName: "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(model.isBaseline ? Color.accentColor : .primary)
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
                                .background(Color.accentColor.opacity(0.12), in: .capsule)
                                .foregroundStyle(Color.accentColor)
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

                Spacer(minLength: 16)

                // Trailing Area: Actions & Status
                trailingArea
            }
            .padding(14)

            // Progress bar if downloading
            if case .downloading(let component, let progress) = status {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(String(format: String(localized: "正在下载 %@…", bundle: appLocalizationBundle), component))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
                .padding(.leading, 54)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            } else if case .checking = status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "正在校验模型文件完整性…", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 54)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            }

            if let error = deletionError {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(String(localized: "重试删除", bundle: appLocalizationBundle), role: .destructive) {
                        onRequestDelete()
                    }
                    .buttonStyle(.borderless)
                    .disabled(isOperating || isDeleting)
                }
                .padding(.leading, 54)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
            } else if let reason = modelError {
                Text(reason).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 54)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 12)
        .overlay(HoverBorder(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            contextMenuItems
        }
        .help(helpText)
    }

    private var helpText: String {
        switch status {
        case .ready:
            return String(localized: "右键查看操作选项（在访达中显示、删除模型）", bundle: appLocalizationBundle)
        case .notDownloaded, .cancelled:
            return String(localized: "右键点击可下载模型", bundle: appLocalizationBundle)
        case .downloading, .checking:
            return String(localized: "右键点击可取消下载", bundle: appLocalizationBundle)
        case .failed, .corrupted:
            return String(localized: "右键点击可重新下载或删除", bundle: appLocalizationBundle)
        case .cancelling:
            return ""
        }
    }

    @ViewBuilder
    private var trailingArea: some View {
        if isDeleting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "正在删除…", bundle: appLocalizationBundle))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            switch status {
            case .ready, .cancelled, .notDownloaded, .failed, .corrupted:
                StatusSignal(modelStatus: status)

            case .downloading, .checking:
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .cancelling:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "正在取消…", bundle: appLocalizationBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        switch status {
        case .ready:
            #if os(macOS)
            if let directory {
                Button {
                    NSWorkspace.shared.open(directory)
                } label: {
                    Label(String(localized: "在访达中显示", bundle: appLocalizationBundle), systemImage: "folder")
                }
                Divider()
            }
            #endif

            Button {
                onRequestDelete()
            } label: {
                Label(String(localized: "删除模型文件", bundle: appLocalizationBundle), systemImage: "trash")
            }
            .disabled(isOperating || isDeleting)

        case .notDownloaded, .cancelled:
            Button {
                onDownload()
            } label: {
                Label(String(localized: "下载模型", bundle: appLocalizationBundle), systemImage: "arrow.down.circle")
            }
            .disabled(isOperating || isDeleting)

        case .downloading, .checking:
            Button {
                onCancel()
            } label: {
                Label(String(localized: "取消下载", bundle: appLocalizationBundle), systemImage: "xmark.circle")
            }

        case .failed, .corrupted:
            Button {
                onDownload()
            } label: {
                Label(String(localized: "重新下载", bundle: appLocalizationBundle), systemImage: "arrow.clockwise")
            }
            .disabled(isOperating || isDeleting)

            #if os(macOS)
            if let directory {
                Button {
                    NSWorkspace.shared.open(directory)
                } label: {
                    Label(String(localized: "在访达中显示", bundle: appLocalizationBundle), systemImage: "folder")
                }
                Divider()
            }
            #endif

            Button {
                onRequestDelete()
            } label: {
                Label(String(localized: "删除模型文件", bundle: appLocalizationBundle), systemImage: "trash")
            }
            .disabled(isOperating || isDeleting)

        case .cancelling:
            EmptyView()
        }
    }
}
