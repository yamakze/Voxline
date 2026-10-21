#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import VoxlineCore

public struct SRTExportSheet: View {
    let mediaTitle: String
    let cues: [SubtitleCue]
    let media: MediaIdentity?
    private let missingTranslationCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: SRTOutputKind
    @State private var fileName: String
    @State private var targetDirectory: URL?
    @State private var errorMessage: String?
    @State private var showDirectoryPicker = false
    @State private var showOverwriteAlert = false
    @State private var exportedURL: URL?
    @State private var exportTask: Task<Void, Never>?

    public init(mediaTitle: String, cues: [SubtitleCue], media: MediaIdentity?, initialKind: SRTOutputKind) {
        self.mediaTitle = mediaTitle
        self.cues = cues
        self.media = media
        missingTranslationCount = cues.reduce(0) { $0 + ($1.hasTranslation ? 0 : 1) }
        _selectedKind = State(initialValue: initialKind)
        _fileName = State(initialValue: SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: initialKind))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.voxlineAccent.opacity(0.12))
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.voxlineAccent)
                }
                .frame(width: 24, height: 24)
                Text(String(localized: "导出 SRT 字幕", bundle: appLocalizationBundle))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 16) {
                Picker(String(localized: "导出类型", bundle: appLocalizationBundle), selection: $selectedKind) {
                    Text(String(localized: "原文 SRT", bundle: appLocalizationBundle)).tag(SRTOutputKind.source)
                    Text(String(localized: "译文 SRT", bundle: appLocalizationBundle)).tag(SRTOutputKind.translation)
                    Text(String(localized: "双语 SRT", bundle: appLocalizationBundle)).tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedKind) { _, kind in
                    fileName = SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: kind)
                    exportedURL = nil
                    errorMessage = nil
                }
                if selectedKind != .source && missingTranslationCount > 0 {
                    Label(String(localized: "有 \(missingTranslationCount) 条字幕缺少有效译文。请完成翻译或校对，或选择原文 SRT。", bundle: appLocalizationBundle), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                TextField(String(localized: "文件名", bundle: appLocalizationBundle), text: $fileName).textFieldStyle(.roundedBorder)
                    .onChange(of: fileName) { _, _ in exportedURL = nil; errorMessage = nil }
                HStack {
                    Text(targetDirectory?.path ?? String(localized: "请选择保存目录", bundle: appLocalizationBundle))
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(String(localized: "选择目录…", bundle: appLocalizationBundle)) { showDirectoryPicker = true }
                }
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
                if let exportedURL {
                    Label(String(localized: "已导出：\(exportedURL.lastPathComponent)", bundle: appLocalizationBundle), systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
            }
            .padding(20)
            .disabled(exportTask != nil)

            HStack {
                Text(String(localized: "\(cues.count) 条字幕 · UTF-8 编码", bundle: appLocalizationBundle))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消", bundle: appLocalizationBundle)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "导出", bundle: appLocalizationBundle)) { export(allowOverwrite: false) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(exportTask != nil || targetDirectory == nil || cues.isEmpty || (selectedKind != .source && missingTranslationCount > 0))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                Color(nsColor: .windowBackgroundColor).opacity(0.7)
                    .background(.regularMaterial)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.4)).frame(height: 1)
            }
        }
        .frame(width: 520)
        .onDisappear { exportTask?.cancel() }
        .fileImporter(isPresented: $showDirectoryPicker, allowedContentTypes: [.folder]) { result in
            do {
                targetDirectory = try result.get()
                errorMessage = nil
                exportedURL = nil
            } catch { errorMessage = error.localizedDescription }
        }
        .alert(String(localized: "文件已存在", bundle: appLocalizationBundle), isPresented: $showOverwriteAlert) {
            Button(String(localized: "取消", bundle: appLocalizationBundle), role: .cancel) {}
            Button(String(localized: "覆盖并导出", bundle: appLocalizationBundle), role: .destructive) { export(allowOverwrite: true) }
        } message: { Text(String(localized: "目录中已存在名为“\(fileName)”的文件。是否确认覆盖？", bundle: appLocalizationBundle)) }
    }

    private func export(allowOverwrite: Bool) {
        guard exportTask == nil, let directory = targetDirectory else { return }
        errorMessage = nil
        exportedURL = nil
        let name = fileName
        let url = directory.appendingPathComponent(name)
        let kind = selectedKind
        exportTask = Task {
            let accessing = directory.startAccessingSecurityScopedResource()
            defer {
                if accessing { directory.stopAccessingSecurityScopedResource() }
                exportTask = nil
            }
            do {
                try SubtitleExporter.validateFileName(name)
                try await SubtitleExporter.export(cues: cues, kind: kind, to: url, media: media, allowOverwrite: allowOverwrite)
                try Task.checkCancellation()
                exportedURL = url
            } catch is CancellationError { return }
            catch SubtitleExportError.fileAlreadyExists { showOverwriteAlert = true }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

#endif
