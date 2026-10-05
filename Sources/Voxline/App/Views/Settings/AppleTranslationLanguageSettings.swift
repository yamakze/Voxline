import SwiftUI
@preconcurrency import Translation

struct AppleTranslationLanguageSettings: View {
    @Binding var source: String
    @Binding var target: String
    @Binding var batchSize: Int
    var allowsEditing = true
    @State private var languages: [Locale.Language] = []
    @State private var status: LanguageAvailability.Status?
    @State private var statusMessage: String?
    @State private var preparation: Task<Void, Never>?
    @State private var isLoadingLanguages = true

    var body: some View {
        Group {
            if !allowsEditing {
                LabeledContent("原文语言", value: Locale.current.localizedString(forIdentifier: source) ?? source)
                LabeledContent("目标语言", value: Locale.current.localizedString(forIdentifier: target) ?? target)
                LabeledContent("每批字幕数", value: String(batchSize))
            } else if isLoadingLanguages {
                ProgressView("读取系统语言…")
            } else if languages.isEmpty {
                Text("当前系统未提供可用的本机翻译语言。")
                    .foregroundStyle(.secondary)
            } else {
                LanguagePicker(title: "原文语言", selection: $source, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(preparation != nil)
                LanguagePicker(title: "目标语言", selection: $target, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(preparation != nil)

                // 语言状态与下载操作行
                HStack(spacing: 8) {
                    if let preparation {
                        ProgressView().controlSize(.small)
                        Text("正在下载语言…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { preparation.cancel() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    } else if let status {
                        switch status {
                        case .installed:
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text("语言已就绪").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                        case .supported:
                            HStack(spacing: 5) {
                                Circle().fill(Color.orange).frame(width: 7, height: 7)
                                Text("需下载语言").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("下载语言") {
                                prepareLanguage()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        case .unsupported:
                            HStack(spacing: 5) {
                                Circle().fill(Color.red).frame(width: 7, height: 7)
                                Text("系统不支持此语言对").font(.caption).foregroundStyle(.red)
                            }
                            Spacer()
                        @unknown default:
                            Spacer()
                        }
                    } else if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ProgressView().controlSize(.mini)
                        Text("检查语言支持…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)

                DisclosureGroup("高级选项") {
                    TextField("每批字幕数", value: $batchSize, format: .number)
                        .disabled(preparation != nil)
                }
            }
        }
        .disabled(preparation != nil && preparation?.isCancelled == true)
        .onDisappear { preparation?.cancel() }
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
        .task(id: source + "→" + target) {
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

    private func prepareLanguage() {
        let selectedSource = source, selectedTarget = target
        preparation = Task {
            defer { preparation = nil }
            do {
                try await AppleTranslationCoordinator.shared.prepareLanguages(sourceID: selectedSource, targetID: selectedTarget)
                let (from, to) = try await AppleTranslationCoordinator.languagePair(sourceID: selectedSource, targetID: selectedTarget)
                status = await LanguageAvailability().status(from: from, to: to)
                statusMessage = nil
            } catch {
                if !(error is CancellationError) {
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}
