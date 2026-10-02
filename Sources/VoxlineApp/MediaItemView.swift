import SwiftUI
import VoxlineCore
import VoxlineMedia
import UniformTypeIdentifiers

struct MediaItemView: View {
    @Binding var item: TaskMediaItem
    @State private var session = MediaItemSession()
    @State private var isChoosingVideo = false
    @State private var isCommittingMedia = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("媒体名称", text: $item.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)

            HStack(spacing: 24) {
                LabeledContent("视频", value: item.media?.fileName ?? "尚未关联")
                LabeledContent("字幕", value: "\(item.cues.count) 条")
                LabeledContent("有效译文", value: "\(item.cues.filter(\.hasCurrentTranslation).count) 条")
            }
            .foregroundStyle(.secondary)
            HStack {
                Button(item.media == nil ? "导入视频…" : "重新关联视频…") { isChoosingVideo = true }
                    .disabled(session.isInspectingMedia || isCommittingMedia)
                if session.isInspectingMedia { ProgressView().controlSize(.small); Text("正在读取媒体信息与校验文件…") }
                else { Text(session.mediaState.label).foregroundStyle(.secondary) }
            }
            if let error = session.mediaError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(item.status.label).font(.callout).foregroundStyle(.secondary)
            Label("播放与字幕编辑尚未接通。当前可关联本地视频并浏览字幕。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)

            if item.cues.isEmpty {
                ContentUnavailableView("媒体还没有字幕", systemImage: "captions.bubble",
                                       description: Text("字幕和校对结果保存在当前任务的媒体条目中。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(item.cues) {
                    TableColumn("时间") { cue in
                        Text(String(format: "%.3f–%.3f 秒", Double(cue.startMilliseconds) / 1000, Double(cue.endMilliseconds) / 1000))
                            .monospacedDigit()
                    }.width(160)
                    TableColumn("原文", value: \.sourceText)
                    TableColumn("译文") { cue in
                        switch cue.translation {
                        case .pending: Text("未翻译").foregroundStyle(.secondary)
                        case .succeeded(let text, _):
                            VStack(alignment: .leading) {
                                Text(text)
                                if !cue.hasCurrentTranslation { Text("原文已修改，需重新翻译").foregroundStyle(.orange) }
                            }
                        case .failed(let reason): Text(reason).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 460)
        .fileImporter(isPresented: $isChoosingVideo,
                      allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, UTType(importedAs: "com.apple.m4v-video")]) { result in
            switch result {
            case .success(let url): Task { await session.inspectVideo(at: url) }
            case .failure(let error): session.mediaError = error.localizedDescription
            }
        }
        .task(id: "\(item.id)-\(item.media?.sha256 ?? "none")-\(item.media?.audioTrackID ?? 0)") {
            await session.restoreMedia(projectID: item.id, identity: item.media)
        }
        .sheet(isPresented: Binding(get: { session.inspection != nil }, set: { if !$0 { session.inspection = nil } })) {
            if let inspection = session.inspection {
                VStack(alignment: .leading, spacing: 16) {
                    Text("选择转写音轨").font(.headline)
                    Text(inspection.url.lastPathComponent)
                    Text(String(format: "时长 %.3f 秒 · %.1f MiB", Double(inspection.durationMilliseconds) / 1000,
                                Double(inspection.byteCount) / 1_048_576)).foregroundStyle(.secondary)
                    ForEach(inspection.videoTracks) { track in
                        Text("视频轨 \(track.id)：\(track.codecs.joined(separator: ", ")) · 可解码")
                    }
                    Picker("音轨", selection: $session.selectedAudioTrackID) {
                        Text("请选择音轨").tag(nil as Int32?)
                        ForEach(inspection.audioTracks) { track in
                            Text("音轨 \(track.id) · \(track.language ?? "未标注语言") · \(track.codecs.joined(separator: ", "))\(track.isDecodable ? "" : " · 无法解码")")
                                .tag(Optional(track.id)).disabled(!track.isDecodable)
                        }
                    }
                    Text("原视频保持在当前位置。重新关联需与当前条目的视频内容和音轨一致。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = session.mediaError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        Button("取消") { session.inspection = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("确认关联") {
                            Task {
                                isCommittingMedia = true
                                defer { isCommittingMedia = false }
                                do {
                                    guard let trackID = session.selectedAudioTrackID else { throw MediaAccessError.invalidAudioTrack }
                                    let candidate = try inspection.identity(audioTrackID: trackID)
                                    var updated = item
                                    let previousMedia = updated.media
                                    try updated.associateMedia(candidate)
                                    if updated.title == "未命名媒体" { updated.title = inspection.url.deletingPathExtension().lastPathComponent }
                                    let current = try await session.inspector.inspect(inspection.url)
                                    guard candidate.matchesContent(of: try current.identity(audioTrackID: trackID)) else {
                                        throw MediaAccessError.fileChanged
                                    }
                                    // Persist the association first; failure leaves the media item unchanged.
                                    try await LocalMediaStore.shared.save(projectID: updated.id, identity: candidate, url: inspection.url)
                                    // Recheck the current item after awaiting persistence.
                                    guard item.id == updated.id, item.media == previousMedia else {
                                        throw MediaAccessError.itemChanged
                                    }
                                    try item.associateMedia(candidate)
                                    if item.title == "未命名媒体" { item.title = updated.title }
                                    session.mediaState = .ready(fileName: inspection.url.lastPathComponent)
                                    session.inspection = nil
                                    session.mediaError = nil
                                } catch { session.mediaError = error.localizedDescription }
                            }
                        }.keyboardShortcut(.defaultAction)
                            .disabled(session.selectedAudioTrackID == nil || isCommittingMedia)
                    }
                }.padding(24).frame(width: 600)
                    .disabled(isCommittingMedia).interactiveDismissDisabled(isCommittingMedia)
            }
        }
    }
}
