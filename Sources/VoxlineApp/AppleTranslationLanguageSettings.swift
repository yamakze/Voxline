import SwiftUI
@preconcurrency import Translation

struct AppleTranslationLanguageSettings: View {
    @Binding var source: String
    @Binding var target: String
    @Binding var batchSize: Int
    @State private var languages: [Locale.Language] = []
    @State private var statusText = "检查语言支持与安装状态…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if languages.isEmpty {
                ProgressView("读取 Apple 支持的语言…")
            } else {
                languagePicker("原文语言", selection: $source)
                languagePicker("目标语言", selection: $target)
            }
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            TextField("每批字幕数量", value: $batchSize, format: .number)
                .textFieldStyle(.roundedBorder)
            Text("开始翻译时由系统请求下载许可；下载后可离线翻译。对白中的多义词仍需播放校对。失败保留成果，可继续或重试。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            let supported = await LanguageAvailability().supportedLanguages.sorted {
                $0.minimalIdentifier < $1.minimalIdentifier
            }
            guard !Task.isCancelled else { return }
            languages = supported
            if let canonical = AppleTranslationCoordinator.matchingLanguage(source, in: supported) {
                source = canonical.minimalIdentifier
            }
            if let canonical = AppleTranslationCoordinator.matchingLanguage(target, in: supported) {
                target = canonical.minimalIdentifier
            }
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

    private func languagePicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            if !languages.contains(where: { $0.minimalIdentifier == selection.wrappedValue }) {
                Text("不支持：\(selection.wrappedValue)").tag(selection.wrappedValue)
            }
            ForEach(languages, id: \.minimalIdentifier) { language in
                Text(Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier)
                    .tag(language.minimalIdentifier)
            }
        }
    }
}
