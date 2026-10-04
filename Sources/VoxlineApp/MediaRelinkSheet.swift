#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct MediaRelinkSheet: View {
    @Binding var item: TaskMediaItem
    @Environment(\.dismiss) private var dismiss

    @State private var showMediaImporter = false
    @State private var isInspecting = false
    @State private var inspection: MediaInspection?
    @State private var selectedAudioTrackID: Int32?
    @State private var errorMessage: String?
    @State private var isCommitting = false

    private let inspector = MediaInspector.shared

    public init(item: Binding<TaskMediaItem>) {
        _item = item
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("重新关联本地媒体").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Text("为“\(item.title)”选择本地原文件。文件内容哈希、时长与所选音轨需与任务记录一致；关联成功后保留现有全部字幕与校对记录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 14) {
                if let media = item.media {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已记录媒体：\(media.fileName)").font(.headline)
                            Text(String(format: "时长 %.3f 秒 · 音轨 ID：%d", Double(media.durationMilliseconds) / 1000.0, media.audioTrackID))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Button("选择本地文件…") {
                    showMediaImporter = true
                }
                .disabled(isInspecting || isCommitting)

                if isInspecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在检查媒体信息与计算内容哈希…").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let inspection {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("所选文件：\(inspection.url.lastPathComponent)").font(.headline)
                        Text(String(format: "时长 %.3f 秒 · 大小 %.1f MB", Double(inspection.durationMilliseconds) / 1000.0, Double(inspection.byteCount) / 1_048_576))
                            .font(.caption).foregroundStyle(.secondary)

                        Picker("确认转写音轨：", selection: $selectedAudioTrackID) {
                            Text("请选择音轨").tag(nil as Int32?)
                            ForEach(inspection.audioTracks) { track in
                                Text("音轨 \(track.id) · \(track.language ?? "未知语言") · \(track.codecs.joined(separator: ", "))\(track.isDecodable ? "" : " (无法解码)")")
                                    .tag(Optional(track.id))
                                    .disabled(!track.isDecodable)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Spacer()
                Button("确认关联") {
                    commitAssociation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inspection == nil || selectedAudioTrackID == nil || isCommitting || isInspecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $showMediaImporter, allowedContentTypes: item.kind == .video
            ? [.mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video")]
            : [.mpeg4Audio, .mp3, .wav]) { result in
            switch result {
            case .success(let url): Task { await inspectFile(at: url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func inspectFile(at url: URL) async {
        isInspecting = true
        errorMessage = nil
        inspection = nil
        defer { isInspecting = false }

        do {
            let result = try await inspector.inspect(url)
            guard result.kind == item.kind else {
                errorMessage = "所选文件格式与媒体类型不一致。"
                return
            }
            inspection = result
            if result.audioTracks.count == 1 {
                selectedAudioTrackID = result.audioTracks[0].id
            } else if let prevID = item.media?.audioTrackID, result.audioTracks.contains(where: { $0.id == prevID }) {
                selectedAudioTrackID = prevID
            } else {
                selectedAudioTrackID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitAssociation() {
        guard let inspection, let trackID = selectedAudioTrackID else { return }
        let original = item
        isCommitting = true
        errorMessage = nil

        Task {
            defer { isCommitting = false }
            do {
                let candidate = try await inspector.confirm(inspection, audioTrackID: trackID)
                if let existing = original.media {
                    guard existing.matchesContent(of: candidate) else {
                        throw ProjectValidationError.differentMedia
                    }
                }

                var updated = original
                try updated.associateMedia(candidate)
                if case .failed = original.status, original.media == nil {
                    updated.status = .pending
                }
                try await LocalMediaStore.shared.save(projectID: original.id, identity: candidate, url: inspection.url)
                guard item == original else { throw MediaAccessError.itemChanged }
                item = updated
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
