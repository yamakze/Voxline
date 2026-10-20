import SwiftUI
@preconcurrency import Translation
#if os(macOS)
import AppKit
#endif

struct AppleTranslationLanguageSettings: View {
    @Binding var source: String
    @Binding var target: String
    @Binding var batchSize: Int
    var allowsEditing = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshID = UUID()
    @State private var languages: [Locale.Language] = []
    @State private var status: LanguageAvailability.Status?
    @State private var statusMessage: String?
    #if os(iOS)
    @State private var configuration: TranslationSession.Configuration?
    @State private var preparation: Task<Void, Never>?
    @State private var preparationID: UUID?
    private var isPreparing: Bool { preparationID != nil }
    #else
    private let isPreparing = false
    #endif
    @State private var isLoadingLanguages = true
    @State private var showAdvanced = false

    var body: some View {
        Group {
            if !allowsEditing {
                LabeledContent(String(localized: "原文语言", bundle: appLocalizationBundle), value: Locale.current.localizedString(forIdentifier: source) ?? source)
                LabeledContent(String(localized: "目标语言", bundle: appLocalizationBundle), value: Locale.current.localizedString(forIdentifier: target) ?? target)
                LabeledContent(String(localized: "每批字幕数", bundle: appLocalizationBundle), value: String(batchSize))
            } else if isLoadingLanguages {
                ProgressView(String(localized: "读取系统语言…", bundle: appLocalizationBundle))
            } else if languages.isEmpty {
                Text(String(localized: "当前系统未提供可用的本机翻译语言。", bundle: appLocalizationBundle))
                    .foregroundStyle(.secondary)
            } else {
                LanguagePicker(title: String(localized: "原文语言", bundle: appLocalizationBundle), selection: $source, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(isPreparing)
                LanguagePicker(title: String(localized: "目标语言", bundle: appLocalizationBundle), selection: $target, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(isPreparing)

                LabeledContent(String(localized: "语言状态", bundle: appLocalizationBundle)) {
                    HStack(spacing: 8) {
                        if isPreparing {
                            ProgressView().controlSize(.mini)
                            Text(String(localized: "正在下载…", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
                            #if os(iOS)
                            Button(String(localized: "取消", bundle: appLocalizationBundle)) { preparation?.cancel(); configuration = nil; preparationID = nil }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            #endif
                        } else if let status {
                            switch status {
                            case .installed:
                                HStack(spacing: 5) {
                                    Circle().fill(Color.green).frame(width: 7, height: 7)
                                    Text(String(localized: "已就绪", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.green)
                                }
                            case .supported:
                                Button {
                                    #if os(macOS)
                                    if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!) {
                                        statusMessage = String(localized: "无法打开系统语言设置。", bundle: appLocalizationBundle)
                                    }
                                    #else
                                    prepareLanguage()
                                    #endif
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                                        Text(String(localized: "需下载", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                .buttonStyle(.plain)
                            case .unsupported:
                                HStack(spacing: 5) {
                                    Circle().fill(Color.red).frame(width: 7, height: 7)
                                    Text(String(localized: "系统不支持此语言对", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.red)
                                }
                            @unknown default:
                                EmptyView()
                            }
                        } else if let statusMessage {
                            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                            Text(String(localized: "检查中…", bundle: appLocalizationBundle)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                            .font(.caption2.bold())
                        Text(String(localized: "高级选项", bundle: appLocalizationBundle))
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)

                if showAdvanced {
                    LabeledContent(String(localized: "每批字幕数", bundle: appLocalizationBundle)) {
                        TextField("", value: $batchSize, format: .number)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .disabled(isPreparing)
                    }
                }
            }
            if let statusMessage, status != nil {
                Text(statusMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshID = UUID() }
        }
        #if os(iOS)
        .onDisappear { preparation?.cancel(); configuration = nil; preparationID = nil }
        #endif
        .task {
            #if targetEnvironment(simulator)
            isLoadingLanguages = false
            #else
            let supported = await LanguageAvailability().supportedLanguages.sorted {
                $0.minimalIdentifier < $1.minimalIdentifier
            }
            guard !Task.isCancelled else { return }
            languages = supported
            isLoadingLanguages = false
            if let canonical = AppleTranslationCoordinator.matchingLanguage(source, in: supported) {
                source = canonical.minimalIdentifier
            }
            if let canonical = AppleTranslationCoordinator.matchingLanguage(target, in: supported) {
                target = canonical.minimalIdentifier
            }
            #endif
        }
        #if os(iOS)
        .translationTask(configuration) { session in
            guard let id = preparationID else { return }
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                let (from, to) = try await AppleTranslationCoordinator.languagePair(sourceID: source, targetID: target)
                let installed = await LanguageAvailability().status(from: from, to: to)
                guard preparationID == id, !Task.isCancelled else { return }
                status = installed
                statusMessage = installed == .installed ? nil : String(localized: "语言下载尚未完成", bundle: appLocalizationBundle)
            } catch {
                guard preparationID == id, !Task.isCancelled else { return }
                if !(error is CancellationError) { statusMessage = error.localizedDescription }
            }
            preparation = nil
            preparationID = nil
        }
        #endif
        .task(id: source + "→" + target + refreshID.uuidString) {
            do {
                let (from, to) = try await AppleTranslationCoordinator.languagePair(sourceID: source, targetID: target)
                let currentStatus = await LanguageAvailability().status(from: from, to: to)
                guard !Task.isCancelled else { return }
                status = currentStatus
                statusMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                status = nil
                statusMessage = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    private func prepareLanguage() {
        let selectedSource = source, selectedTarget = target
        statusMessage = nil
        let id = UUID()
        preparationID = id
        preparation = Task {
            do {
                let (from, to) = try await AppleTranslationCoordinator.languagePair(sourceID: selectedSource, targetID: selectedTarget)
                try Task.checkCancellation()
                guard preparationID == id else { return }
                if var current = configuration, current.source == from, current.target == to {
                    current.invalidate()
                    configuration = current
                } else { configuration = TranslationSession.Configuration(source: from, target: to) }
            } catch {
                guard preparationID == id else { return }
                preparationID = nil
                if !(error is CancellationError) {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
    #endif
}
