#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore
import VoxlineMedia

public struct MediaRelinkSheet: View {
    let item: TaskMediaItem
    let onCommit: (TaskMediaItem, TaskMediaItem) throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showMediaImporter = false
    @State private var isInspecting = false
    @State private var inspection: MediaInspection?
    @State private var selectedAudioTrackID: Int32?
    @State private var errorMessage: String?
    @State private var isCommitting = false

    private let inspector = MediaInspector.shared

    public init(item: TaskMediaItem, onCommit: @escaping (TaskMediaItem, TaskMediaItem) throws -> Void) {
        self.item = item
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(String(localized: "重新关联本地媒体", bundle: appLocalizationBundle)).font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                if let media = item.media {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "已记录媒体：\(media.fileName)", bundle: appLocalizationBundle)).font(.headline)
                            Text(String(format: String(localized: "时长 %.3f 秒", bundle: appLocalizationBundle), locale: .current, Double(media.durationMilliseconds) / 1000.0))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Button(String(localized: "选择本地文件…", bundle: appLocalizationBundle)) {
                    showMediaImporter = true
                }
                .disabled(isInspecting || isCommitting)

                if isInspecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "检查媒体…", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let inspection {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "所选文件：\(inspection.url.lastPathComponent)", bundle: appLocalizationBundle)).font(.headline)
                        Text(String(format: String(localized: "时长 %.3f 秒 · 大小 %.1f MB", bundle: appLocalizationBundle), locale: .current, Double(inspection.durationMilliseconds) / 1000.0, Double(inspection.byteCount) / 1_048_576))
                            .font(.caption).foregroundStyle(.secondary)

                        Picker(String(localized: "播放音轨", bundle: appLocalizationBundle), selection: $selectedAudioTrackID) {
                            Text(String(localized: "请选择音轨", bundle: appLocalizationBundle)).tag(nil as Int32?)
                            ForEach(inspection.audioTracks) { track in
                                Text(String(localized: "音轨 \(track.id) · \(track.language ?? String(localized: "未知语言", bundle: appLocalizationBundle)) · \(track.codecs.joined(separator: ", "))\(track.isDecodable ? "" : String(localized: " (无法解码)", bundle: appLocalizationBundle))", bundle: appLocalizationBundle))
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

            HStack(spacing: 12) {
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "确认关联", bundle: appLocalizationBundle)) {
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
                errorMessage = String(localized: "所选文件格式与媒体类型不一致。", bundle: appLocalizationBundle)
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

                var updated = original
                try updated.associateMedia(candidate)
                if case .failed = original.status, original.media == nil {
                    updated.status = .pending
                }
                try await LocalMediaStore.shared.save(mediaID: original.id, identity: candidate, url: inspection.url)
                try onCommit(updated, original)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#endif
