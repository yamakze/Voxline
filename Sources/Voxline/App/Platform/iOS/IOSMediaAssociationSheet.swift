#if os(iOS)
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
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
    @State private var selectedURL: URL
    @State private var inspectionRequestID = UUID()
    @State private var isInspecting = false
    @State private var canRetryInspection = false
    @State private var isSelectingMedia = false

    init(candidate: IOSMediaAssociationCandidate, onCommit: @escaping (TaskMediaItem) throws -> Void) {
        self.candidate = candidate
        self.onCommit = onCommit
        _selectedURL = State(initialValue: candidate.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("所选媒体") {
                    Text(selectedURL.lastPathComponent)
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
                    } else if isInspecting { ProgressView("检查媒体…") }
                    Button("重新选择…") { isSelectingMedia = true }
                        .disabled(isInspecting || isSaving)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if inspection == nil, canRetryInspection {
                            Button("重试检查") { inspectionRequestID = UUID() }
                                .disabled(isInspecting || isSaving)
                        }
                    }
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
                                try await LocalMediaStore.shared.save(projectID: item.id, identity: identity, url: selectedURL)
                                try onCommit(item)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(inspection == nil || trackID == nil || isSaving)
                }
            }
            .fileImporter(isPresented: $isSelectingMedia,
                          allowedContentTypes: candidate.item.kind == .video ? [.movie] : [.audio]) { result in
                do {
                    let url = try result.get()
                    if accessStarted { selectedURL.stopAccessingSecurityScopedResource() }
                    accessStarted = false
                    selectedURL = url
                    inspection = nil
                    trackID = nil
                    errorMessage = nil
                    inspectionRequestID = UUID()
                } catch { errorMessage = error.localizedDescription }
            }
            .task(id: inspectionRequestID) {
                isInspecting = true
                errorMessage = nil
                canRetryInspection = false
                defer { isInspecting = false }
                if !accessStarted { accessStarted = selectedURL.startAccessingSecurityScopedResource() }
                do {
                    let value = try await MediaInspector.shared.inspect(selectedURL)
                    try Task.checkCancellation()
                    guard value.kind == candidate.item.kind else { throw MediaAccessError.unsupportedFormat }
                    inspection = value
                    if let media = candidate.item.media { trackID = media.audioTrackID }
                    else if value.audioTracks.count == 1 { trackID = value.audioTracks[0].id }
                } catch is CancellationError {
                    errorMessage = "媒体检查已取消。"
                    canRetryInspection = true
                } catch {
                    errorMessage = error.localizedDescription
                    // Content and codec failures require a different file; only transient failures can retry.
                    if let mediaError = error as? MediaAccessError {
                        canRetryInspection = mediaError == .fileChanged
                    } else if let mediaError = error as? AVError {
                        switch mediaError.code {
                        case .fileFormatNotRecognized, .fileFailedToParse, .invalidSourceMedia, .decodeFailed,
                             .decoderNotFound, .undecodableMediaData, .formatUnsupported,
                             .contentIsProtected, .operationNotSupportedForAsset:
                            canRetryInspection = false
                        default: canRetryInspection = true
                        }
                    } else { canRetryInspection = true }
                }
            }
            .onDisappear {
                if accessStarted {
                    selectedURL.stopAccessingSecurityScopedResource()
                    accessStarted = false
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}

#endif
