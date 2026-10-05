import SwiftUI
@preconcurrency import Translation

struct AppleTranslationLanguageSettings: View {
    @Binding var source: String
    @Binding var target: String
    @Binding var batchSize: Int
    var allowsEditing = true
    @State private var languages: [Locale.Language] = []
    @State private var statusText = "检查语言支持与安装状态…"
    @State private var preparation: Task<Void, Never>?
    @State private var isLoadingLanguages = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !allowsEditing {
                LabeledContent("原文语言", value: Locale.current.localizedString(forIdentifier: source) ?? source)
                LabeledContent("目标语言", value: Locale.current.localizedString(forIdentifier: target) ?? target)
                LabeledContent("每批字幕数量", value: String(batchSize))
            } else if isLoadingLanguages {
                ProgressView("读取 Apple 支持的语言…")
            } else if languages.isEmpty {
                Text("当前系统未提供可用的本机翻译语言。")
            } else {
                LanguagePicker(title: "原文语言", selection: $source, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(preparation != nil)
                LanguagePicker(title: "目标语言", selection: $target, identifiers: languages.map(\.minimalIdentifier))
                    .disabled(preparation != nil)
            }
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if allowsEditing {
                TextField("每批字幕数量", value: $batchSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .disabled(preparation != nil)
            }
            if preparation != nil {
                ProgressView("等待系统许可并下载语言…")
                Button("取消语言准备") { preparation?.cancel() }
            } else {
                Button("准备语言") {
                    let selectedSource = source, selectedTarget = target
                    preparation = Task {
                        defer { preparation = nil }
                        do {
                            try await AppleTranslationCoordinator.shared.prepareLanguages(sourceID: selectedSource, targetID: selectedTarget)
                            statusText = "语言已安装，可在本机翻译。"
                        } catch {
                            statusText = error is CancellationError ? "语言准备已取消，可重试。" : error.localizedDescription
                        }
                    }
                }
            }
            Text("请先通过“准备语言”允许系统下载；完成后再开始翻译，可离线使用。对白中的多义词仍需播放校对。失败保留成果，可继续或重试。")
                .font(.caption).foregroundStyle(.secondary)
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
                let status = await LanguageAvailability().status(from: from, to: to)
                guard !Task.isCancelled else { return }
                switch status {
                case .installed: statusText = "语言已安装，可在本机翻译。"
                case .supported: statusText = "支持此语言对，需要下载语言。"
                case .unsupported: statusText = "不支持此语言对。"
                @unknown default: statusText = "无法识别系统返回的语言状态。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                statusText = error.localizedDescription
            }
        }
    }

}
