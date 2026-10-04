import SwiftUI
import VoxlineCore
import VoxlineMedia

struct IOSMediaAssociationCandidate: Identifiable {
    let id = UUID()
    let url: URL
    let item: TaskMediaItem
}

struct IOSMediaAssociationSheet: View {
    let candidate: IOSMediaAssociationCandidate
    let onCommit: (TaskMediaItem) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: MediaInspection?
    @State private var trackID: Int32?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var accessStarted = false

    var body: some View {
        NavigationStack {
            Form {
                Section("所选媒体") {
                    Text(candidate.url.lastPathComponent)
                    if let inspection {
                        LabeledContent("时长", value: "\((Double(inspection.durationMilliseconds) / 1000).formatted(.number.precision(.fractionLength(1)))) 秒")
                        Picker("播放音轨", selection: $trackID) {
                            Text("请选择音轨").tag(nil as Int32?)
                            ForEach(inspection.audioTracks) { track in
                                Text("音轨 \(track.id) · \(track.language ?? "未标明语言") · \(track.codecs.joined(separator: ", "))")
                                    .tag(Optional(track.id))
                                    .disabled(!track.isDecodable || candidate.item.media.map { $0.audioTrackID != track.id } == true)
                            }
                        }
                        if candidate.item.media != nil {
                            Text("保持 Mac 任务的媒体内容和所选音轨，字幕与校对成果不变。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if errorMessage == nil { ProgressView("检查媒体…") }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("关联媒体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关联") {
                        Task {
                            isSaving = true
                            defer { isSaving = false }
                            do {
                                guard let inspection, let trackID else { throw MediaAccessError.invalidAudioTrack }
                                let identity = try await MediaInspector.shared.confirm(inspection, audioTrackID: trackID)
                                var item = candidate.item
                                try item.associateMedia(identity)
                                try await LocalMediaStore.shared.save(projectID: item.id, identity: identity, url: candidate.url)
                                try onCommit(item)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(inspection == nil || trackID == nil || isSaving)
                }
            }
            .task {
                accessStarted = candidate.url.startAccessingSecurityScopedResource()
                do {
                    let value = try await MediaInspector.shared.inspect(candidate.url)
                    guard value.kind == candidate.item.kind else { throw MediaAccessError.unsupportedFormat }
                    inspection = value
                    if let media = candidate.item.media { trackID = media.audioTrackID }
                    else if value.audioTracks.count == 1 { trackID = value.audioTracks[0].id }
                } catch is CancellationError { errorMessage = "媒体检查已取消。" }
                catch { errorMessage = error.localizedDescription }
            }
            .onDisappear {
                if accessStarted { candidate.url.stopAccessingSecurityScopedResource() }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}
