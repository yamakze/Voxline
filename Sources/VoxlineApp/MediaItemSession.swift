import Observation
import Foundation
import VoxlineCore
import VoxlineMedia

@Observable
@MainActor
final class MediaItemSession {
    var mediaState: MediaState = .unassociated
    var inspection: MediaInspection?
    var selectedAudioTrackID: Int32?
    var isInspectingMedia = false
    var mediaError: String?
    let inspector = MediaInspector()

    func inspectVideo(at url: URL) async {
        isInspectingMedia = true
        mediaError = nil
        defer { isInspectingMedia = false }
        do {
            let candidate = try await inspector.inspect(url)
            inspection = candidate
            selectedAudioTrackID = candidate.audioTracks.count == 1 ? candidate.audioTracks[0].id : nil
        } catch is CancellationError {
            mediaError = "视频检查已取消。"
        } catch { mediaError = error.localizedDescription }
    }

    func restoreMedia(projectID: UUID, identity: MediaIdentity?) async {
        guard let identity else { mediaState = .unassociated; return }
        mediaState = .checking
        do {
            guard let bookmark = try await LocalMediaStore.shared.resolve(projectID: projectID, identity: identity) else {
                mediaState = .needsRelink("此设备尚未关联视频，请选择原视频。")
                return
            }
            let actual = try await inspector.inspect(bookmark.url)
            guard identity.matchesContent(of: try actual.identity(audioTrackID: identity.audioTrackID)) else {
                throw ProjectValidationError.differentMedia
            }
            if bookmark.isStale {
                try await LocalMediaStore.shared.save(projectID: projectID, identity: identity, url: bookmark.url)
            }
            mediaState = .ready(fileName: bookmark.url.lastPathComponent)
        } catch is CancellationError {
            mediaState = .needsRelink("媒体检查已取消，请重新检查或关联。")
        } catch { mediaState = .needsRelink(error.localizedDescription) }
    }
}

enum MediaState {
    case unassociated, checking, ready(fileName: String), needsRelink(String)
    var label: String {
        switch self {
        case .unassociated: "此设备尚未关联视频"
        case .checking: "正在检查本地视频"
        case .ready(let fileName): "本地视频可用：\(fileName)"
        case .needsRelink(let reason): "需要重新关联：\(reason)"
        }
    }
}
