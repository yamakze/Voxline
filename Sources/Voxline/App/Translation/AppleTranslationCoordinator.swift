import Foundation
import Observation
import SwiftUI
@preconcurrency import Translation
import VoxlineCore
import VoxlineTranslation

enum AppleSubtitleTranslationError: Error, LocalizedError, Equatable {
    case unsupportedLanguagePair(String, String)
    case busy
    case invalidResponse
    case languagesNotInstalled
    case simulatorUnsupported

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguagePair(let source, let target):
            String(localized: "Apple Translation 不支持 \(source) → \(target)。请选择支持的语言对。", bundle: appLocalizationBundle)
        case .busy: String(localized: "Apple Translation 正在完成上一批字幕，请稍后重试。", bundle: appLocalizationBundle)
        case .invalidResponse: String(localized: "Apple Translation 返回的字幕 ID 或文本不完整，本批结果未保存。", bundle: appLocalizationBundle)
        case .languagesNotInstalled: String(localized: "请在语言设置中完成下载后继续翻译。", bundle: appLocalizationBundle)
        case .simulatorUnsupported: String(localized: "Apple 本机翻译不支持 iOS 模拟器，请在真实设备准备语言并翻译。", bundle: appLocalizationBundle)
        }
    }
}

/// View sessions stay inside the stable root's translationTask on macOS 15 / iOS 18.
/// Cancelling a queue request waits for the SDK call to end before releasing the queue.
@MainActor @Observable
final class AppleTranslationCoordinator {
    static let shared = AppleTranslationCoordinator()

    private struct Work {
        let id: UUID
        let inputs: [TranslationBatchInput]
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<[TranslationBatchOutput], any Error>
        var started = false
        var cancelled = false
    }

    var configuration: TranslationSession.Configuration?
    private var lastConfiguration: TranslationSession.Configuration?
    private var work: Work?
    private var cancelSession: (() -> Void)?

    func translate(settings: TranslationSettings, request: SubtitleTranslationRequest) async throws -> [TranslationBatchOutput] {
        try settings.validate()
        guard case .appleTranslation(let sourceID) = settings.engine else {
            throw SubtitleTranslationError.invalidRequest
        }
        let (source, target) = try await Self.languagePair(sourceID: sourceID, targetID: settings.targetLanguage)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            throw AppleSubtitleTranslationError.languagesNotInstalled
        }
        return try await requestSession(inputs: request.inputs, source: source, target: target)
    }

    private func requestSession(inputs: [TranslationBatchInput], source: Locale.Language, target: Locale.Language) async throws -> [TranslationBatchOutput] {
        try Task.checkCancellation()
        guard work == nil else { throw AppleSubtitleTranslationError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                work = Work(id: id, inputs: inputs, source: source, target: target, continuation: continuation)
                var next = lastConfiguration ?? TranslationSession.Configuration(source: source, target: target)
                if next.source != source || next.target != target {
                    next = TranslationSession.Configuration(source: source, target: target)
                } else { next.invalidate() }
                lastConfiguration = next
                configuration = next
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    static func languagePair(sourceID: String, targetID: String) async throws -> (Locale.Language, Locale.Language) {
        #if targetEnvironment(simulator)
        throw AppleSubtitleTranslationError.simulatorUnsupported
        #else
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        guard let source = matchingLanguage(sourceID, in: languages),
              let target = matchingLanguage(targetID, in: languages),
              await availability.status(from: source, to: target) != .unsupported else {
            throw AppleSubtitleTranslationError.unsupportedLanguagePair(sourceID, targetID)
        }
        return (source, target)
        #endif
    }

    nonisolated static func matchingLanguage(_ identifier: String, in languages: [Locale.Language]) -> Locale.Language? {
        languages.first { $0.minimalIdentifier == identifier }
            ?? languages.first { $0.isEquivalent(to: Locale.Language(identifier: identifier)) }
    }

    private func cancel(id: UUID) {
        guard var current = work, current.id == id else { return }
        current.cancelled = true
        work = current
        configuration = nil
        cancelSession?()
        if !current.started {
            work = nil
            current.continuation.resume(throwing: CancellationError())
        }
    }

    func translateInViewSession(_ viewSession: TranslationSession) async {
        guard var current = work, !current.started else { return }
        current.started = true
        work = current
        let result: Result<[TranslationBatchOutput], any Error>
        do {
            let session: TranslationSession
            guard await LanguageAvailability().status(from: current.source, to: current.target) == .installed else {
                throw AppleSubtitleTranslationError.languagesNotInstalled
            }
            if #available(macOS 26, iOS 26, *) {
                session = TranslationSession(installedSource: current.source, target: current.target)
                cancelSession = { session.cancel() }
            } else { session = viewSession }
            try Task.checkCancellation()
            if work?.cancelled == true { throw CancellationError() }
            let responses = try await session.translations(from: Self.requests(inputs: current.inputs))
            try Task.checkCancellation()
            if work?.cancelled == true { throw CancellationError() }
            result = .success(try Self.outputs(responses, inputs: current.inputs))
        } catch {
            result = .failure(work?.cancelled == true ? CancellationError() : error)
        }
        guard work?.id == current.id else { return }
        work = nil
        configuration = nil
        cancelSession = nil
        current.continuation.resume(with: result)
    }

    private nonisolated static func requests(inputs: [TranslationBatchInput]) -> sending [TranslationSession.Request] {
        inputs.map { TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: $0.cueID.uuidString) }
    }

    static func outputs(_ responses: [TranslationSession.Response], inputs: [TranslationBatchInput]) throws -> [TranslationBatchOutput] {
        let expected = Set(inputs.map(\.cueID))
        var texts: [UUID: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier, let id = UUID(uuidString: identifier),
                  expected.contains(id), texts[id] == nil,
                  !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppleSubtitleTranslationError.invalidResponse
            }
            texts[id] = response.targetText
        }
        guard Set(texts.keys) == expected else { throw AppleSubtitleTranslationError.invalidResponse }
        return try inputs.map {
            guard let text = texts[$0.cueID] else { throw AppleSubtitleTranslationError.invalidResponse }
            return TranslationBatchOutput(cueID: $0.cueID, text: text)
        }
    }
}

struct AppleTranslationSessionHost: View {
    @State private var coordinator = AppleTranslationCoordinator.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(coordinator.configuration) { session in
                await coordinator.translateInViewSession(session)
            }
            .accessibilityHidden(true)
    }
}
