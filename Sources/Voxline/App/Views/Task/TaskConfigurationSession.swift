import Foundation
import Observation
import VoxlineCore
import VoxlineMedia
import VoxlineTranslation

/// Task preparation owns its draft and media operations; platform views supply the save boundary.
@Observable @MainActor
final class TaskConfigurationSession {
    var draftTitle: String
    var transcriptionProvider: TranscriptionSettings.Provider
    var selectedCloudServiceID: UUID?
    var modelID: String
    var languageMode: TranscriptionSettings.LanguageMode
    var languageCode: String
    enum TranslationEngineChoice { case api, apple }
    var translationEngine: TranslationEngineChoice
    var appleSourceLanguage: String
    var appleBatchSize: Int
    var translates: Bool
    var selectedServiceID: UUID?
    var translationModel: String
    var targetLanguage: String
    var translationBatchSize: Int
    var translationSystemPrompt: String

    var existingItems: [TaskMediaItem]
    var candidates: [ImportCandidate] = []
    var subtitleImports: [UUID: SubtitleImportSelection] = [:]
    var speechRecognitionSelections = Set<UUID>()
    private(set) var isInspecting = false
    private(set) var isSaving = false
    var errorMessage: String?
    let originalTask: ProcessingTask
    private let inspector: MediaInspector
    private let mediaStore: LocalMediaStore
    let serviceStore: TranslationServiceStore
    let cloudStore: CloudTranscriptionServiceStore
    private let prepareLanguages: (String, String) async throws -> Void
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(task value: ProcessingTask, inspector: MediaInspector = .shared,
         mediaStore: LocalMediaStore = .shared, serviceStore: TranslationServiceStore = .shared,
         cloudStore: CloudTranscriptionServiceStore = .shared,
         prepareLanguages: @escaping (String, String) async throws -> Void = { source, target in
             _ = try await AppleTranslationCoordinator.languagePair(sourceID: source, targetID: target)
         }) {
        self.inspector = inspector
        self.mediaStore = mediaStore
        self.serviceStore = serviceStore
        self.cloudStore = cloudStore
        self.prepareLanguages = prepareLanguages
        originalTask = value
        draftTitle = value.title
        transcriptionProvider = value.parameters.transcription.provider
        selectedCloudServiceID = value.parameters.transcription.cloud?.serviceID
        modelID = value.parameters.transcription.provider == .whisperKit
            ? value.parameters.transcription.modelID : TranscriptionSettings.whisperKitBaseline.modelID
        languageMode = value.parameters.transcription.languageMode
        languageCode = value.parameters.transcription.languageCode ?? "en"
        if case .appleTranslation(let source) = value.parameters.translation?.engine {
            translationEngine = .apple
            appleSourceLanguage = source
            appleBatchSize = value.parameters.translation?.batchSize ?? TranslationSettings.defaultBatchSize
        } else {
            translationEngine = .api
            appleSourceLanguage = "en"
            appleBatchSize = TranslationSettings.defaultBatchSize
        }
        translates = value.parameters.translation != nil
        selectedServiceID = value.parameters.translation?.api?.serviceID
        translationModel = value.parameters.translation?.api?.modelID ?? "gpt-4o-mini"
        targetLanguage = value.parameters.translation?.targetLanguage ?? "zh-Hans"
        translationBatchSize = value.parameters.translation?.batchSize ?? TranslationSettings.defaultBatchSize
        translationSystemPrompt = value.parameters.translation?.api?.systemPrompt ?? TranslationSettings.defaultSystemPrompt
        existingItems = value.items
    }

    struct ImportCandidate: Identifiable {
        let id = UUID()
        let url: URL
        let kind: TaskMediaKind
        var inspection: MediaInspection?
        var trackID: Int32?
        var error: String?
    }

    func cancelImport() { importTask?.cancel() }

    var requiresSpeechRecognition: Bool {
        if existingItems.isEmpty && candidates.isEmpty { return true }
        return existingItems.contains { speechRecognitionSelections.contains($0.id) || (subtitleImports[$0.id] == nil && $0.importedSubtitleOrigin == nil) } ||
        candidates.contains { $0.error == nil && subtitleImports[$0.id] == nil }
    }

    func subtitleImportItem(for id: UUID) throws -> TaskMediaItem {
        if let item = existingItems.first(where: { $0.id == id }) { return item }
        guard let candidate = candidates.first(where: { $0.id == id }),
              let inspection = candidate.inspection, let trackID = candidate.trackID else {
            throw TaskConfigurationError.missingTrack(candidates.first(where: { $0.id == id })?.url.lastPathComponent ?? "")
        }
        let media = try inspection.identity(audioTrackID: trackID)
        return TaskMediaItem(id: id, title: candidate.url.deletingPathExtension().lastPathComponent,
            kind: candidate.kind, source: .localFile(fileName: media.fileName), media: media)
    }

    var preflightBlockReason: String? {
        let totalCount = existingItems.count + candidates.filter({ $0.error == nil }).count
        if totalCount == 0 {
            return String(localized: "请先在左侧添加音视频。", bundle: appLocalizationBundle)
        }
        for candidate in candidates where candidate.error == nil {
            if candidate.inspection != nil && candidate.trackID == nil {
                return String(localized: "媒体“\(candidate.url.lastPathComponent)”尚未选择音轨。", bundle: appLocalizationBundle)
            }
        }
        if requiresSpeechRecognition && transcriptionProvider == .openAICompatible, selectedCloudServiceID == nil || selectedCloudServiceID != originalTask.parameters.transcription.cloud?.serviceID {
            if cloudStore.isLoading || cloudStore.isSaving { return String(localized: "云端转写服务配置正在读取或保存。", bundle: appLocalizationBundle) }
            if let error = cloudStore.errorMessage { return error }
            if !cloudStore.services.contains(where: { $0.id == selectedCloudServiceID }) {
                return String(localized: "开启云端转写需选择已配置的转写服务。", bundle: appLocalizationBundle)
            }
            if let service = cloudStore.services.first(where: { $0.id == selectedCloudServiceID }) {
                do {
                    _ = try service.settings(languageCode: languageMode == .specified
                        ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil)
                } catch { return error.localizedDescription }
            }
        }
        if translates && translationEngine == .api {
            if serviceStore.isLoading || serviceStore.isSaving { return String(localized: "翻译服务配置正在读取或保存。", bundle: appLocalizationBundle) }
            if let error = serviceStore.errorMessage { return error }
            if selectedServiceID == nil || serviceStore.services.isEmpty {
                return String(localized: "开启翻译时需选择已配置的翻译服务。", bundle: appLocalizationBundle)
            }
            if translationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(localized: "翻译模型名称不能为空。", bundle: appLocalizationBundle)
            }
        }
        return nil
    }

    func commit(comparedTo currentTask: () -> ProcessingTask,
                discardingTranslations: Bool = false,
                onCommit: (ProcessingTask) throws -> Void) async throws -> ProcessingTask {
        try Task.checkCancellation()
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let transcription: TranscriptionSettings
        if !requiresSpeechRecognition {
            transcription = originalTask.parameters.transcription
        } else if transcriptionProvider == .whisperKit {
            transcription = TranscriptionSettings(
                provider: .whisperKit,
                modelID: modelID,
                languageMode: languageMode,
                languageCode: languageMode == .specified ? languageCode : nil,
                cloud: nil
            )
        } else if let cloud = originalTask.parameters.transcription.cloud, selectedCloudServiceID == cloud.serviceID {
            transcription = TranscriptionSettings(provider: .openAICompatible,
                modelID: originalTask.parameters.transcription.modelID, languageMode: languageMode,
                languageCode: languageMode == .specified ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil,
                cloud: cloud)
        } else {
            guard let serviceID = selectedCloudServiceID,
                  let service = cloudStore.services.first(where: { $0.id == serviceID }) else {
                throw CloudTranscriptionError.unconfiguredService
            }
            transcription = try service.settings(languageCode: languageMode == .specified ? languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil)
        }

        var translation: TranslationSettings?
        if translates && translationEngine == .apple {
            try await prepareLanguages(appleSourceLanguage, targetLanguage)
            translation = try TranslationSettings(appleSourceLanguage: appleSourceLanguage,
                                                  targetLanguage: targetLanguage, batchSize: appleBatchSize)
        } else if translates {
            guard let serviceID = selectedServiceID,
                  let service = serviceStore.services.first(where: { $0.id == serviceID }) else {
                throw TaskValidationError.unconfiguredTranslationService
            }
            translation = try TranslationSettings(
                baseURL: service.baseURL,
                modelID: translationModel,
                targetLanguage: targetLanguage,
                serviceID: serviceID,
                batchSize: translationBatchSize, systemPrompt: translationSystemPrompt
            )
        }

        var updated = originalTask
        updated.title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if updated.title.isEmpty { updated.title = String(localized: "未命名任务", bundle: appLocalizationBundle) }

        var newItems: [TaskMediaItem] = existingItems
        var addedBookmarkPairs: [(TaskMediaItem, MediaInspection, Int32)] = []

        for candidate in candidates {
            if let failure = candidate.error {
                let failedItem = TaskMediaItem(
                    id: candidate.id,
                    title: candidate.url.deletingPathExtension().lastPathComponent,
                    kind: candidate.kind,
                    source: .localFile(fileName: candidate.url.lastPathComponent),
                    status: .failed(reason: failure)
                )
                newItems.append(failedItem)
                continue
            }

            guard let inspection = candidate.inspection, let trackID = candidate.trackID else {
                throw TaskConfigurationError.missingTrack(candidate.url.lastPathComponent)
            }

            var item = TaskMediaItem(
                id: candidate.id,
                title: candidate.url.deletingPathExtension().lastPathComponent,
                kind: candidate.kind,
                source: .unassociated
            )
            try item.associateMedia(inspection.identity(audioTrackID: trackID))
            newItems.append(item)
            addedBookmarkPairs.append((item, inspection, trackID))
        }

        updated.items = newItems
        try updated.updateParameters(TaskParameters(
            transcription: transcription, translation: translation
        ), discardingTranslations: discardingTranslations)

        for (item, inspection, trackID) in addedBookmarkPairs {
            do {
                let access = inspection.url.startAccessingSecurityScopedResource()
                defer { if access { inspection.url.stopAccessingSecurityScopedResource() } }

                let identity = try await inspector.confirm(inspection, audioTrackID: trackID)
                try await mediaStore.save(mediaID: item.id, identity: identity, url: inspection.url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let index = updated.items.firstIndex(where: { $0.id == item.id }) {
                    updated.items[index] = TaskMediaItem(id: item.id, title: item.title, kind: item.kind,
                        source: .localFile(fileName: inspection.url.lastPathComponent),
                        status: .failed(reason: error.localizedDescription))
                }
            }
        }
        try Task.checkCancellation()
        for item in updated.items {
            if let selection = subtitleImports[item.id] {
                try updated.importOriginalSubtitles(mediaID: item.id, entries: selection.entries,
                    origin: selection.origin, comparedTo: item, replacingExisting: true)
            } else if speechRecognitionSelections.contains(item.id) {
                try updated.useSpeechRecognition(mediaID: item.id, comparedTo: item)
            }
        }
        guard currentTask() == originalTask else { throw TaskValidationError.taskChanged }
        try updated.validate()
        try onCommit(updated)
        return updated
    }

    func importMediaURLs(_ urls: [URL]) {
        guard importTask == nil else {
            errorMessage = TaskConfigurationError.importInProgress.localizedDescription
            return
        }
        isInspecting = true
        importTask = Task {
            defer { isInspecting = false; importTask = nil }

            let additions = urls.filter { url in
                !candidates.contains { $0.url == url }
            }

            for url in additions {
                if Task.isCancelled { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }

                let kind: TaskMediaKind
                do { kind = try MediaInspector.kind(of: url) }
                catch {
                    errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
                    continue
                }
                let candidate = ImportCandidate(url: url, kind: kind)
                candidates.append(candidate)
                do {
                    let inspection = try await inspector.inspect(url)
                    try Task.checkCancellation()
                    if let idx = candidates.firstIndex(where: { $0.id == candidate.id }) {
                        candidates[idx].inspection = inspection
                        if inspection.audioTracks.count == 1 {
                            candidates[idx].trackID = inspection.audioTracks[0].id
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if let idx = candidates.firstIndex(where: { $0.id == candidate.id }) {
                        candidates[idx].error = error.localizedDescription
                    }
                }
            }
        }
    }
}

enum TaskConfigurationError: LocalizedError {
    case missingTrack(String), importInProgress
    var errorDescription: String? {
        switch self {
        case .missingTrack(let name): String(localized: "\(name)：请先选择转写音轨。", bundle: appLocalizationBundle)
        case .importInProgress: String(localized: "正在读取媒体，请稍后再试。", bundle: appLocalizationBundle)
        }
    }
}
