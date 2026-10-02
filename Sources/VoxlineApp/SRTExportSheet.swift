import SwiftUI
import AppKit
import VoxlineCore

public struct SRTExportSheet: View {
    let mediaTitle: String
    let cues: [SubtitleCue]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: SRTOutputKind = .source
    @State private var fileName: String = ""
    @State private var targetDirectory: URL?
    @State private var errorMessage: String?
    @State private var showOverwriteAlert = false
    @State private var isExporting = false
    @State private var exportSuccess = false

    public init(mediaTitle: String, cues: [SubtitleCue]) {
        self.mediaTitle = mediaTitle
        self.cues = cues
    }

    private var hasValidTranslations: Bool {
        cues.contains { $0.hasCurrentTranslation }
    }

    private var targetFileURL: URL? {
        targetDirectory?.appendingPathComponent(fileName)
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("导出 SRT 字幕").font(.headline)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 16) {
                Picker("导出类型", selection: $selectedKind) {
                    Text("原文 SRT").tag(SRTOutputKind.source)
                    Text("译文 SRT").tag(SRTOutputKind.translation)
                    Text("双语 SRT").tag(SRTOutputKind.bilingual)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedKind) { _, newKind in
                    fileName = SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: newKind)
                }

                if selectedKind != .source && !hasValidTranslations {
                    Label("当前媒体尚未生成有效译文，无法导出译文或双语字幕。请先完成翻译或选择导出原文。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("文件名：").font(.caption).foregroundStyle(.secondary)
                    TextField("文件名", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("保存目录：").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(targetDirectory?.path ?? "未选择保存目录（默认下载目录）")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(targetDirectory == nil ? .secondary : .primary)
                        Spacer()
                        Button("选择目录…") { chooseDirectory() }
                    }
                }

                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                }

                if exportSuccess {
                    Label("字幕已成功导出（UTF-8 编码）。", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            .padding()
            .liquidGlassSurface()

            HStack {
                Text("\(cues.count) 条字幕 · UTF-8 编码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("导出") {
                    attemptExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExportDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            fileName = SubtitleExporter.suggestedFileName(mediaTitle: mediaTitle, kind: selectedKind)
            if targetDirectory == nil {
                targetDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            }
        }
        .alert("文件已存在", isPresented: $showOverwriteAlert) {
            Button("取消", role: .cancel) {}
            Button("覆盖并导出", role: .destructive) {
                performExport(allowOverwrite: true)
            }
        } message: {
            Text("目录中已存在名为“\(fileName)”的文件。是否确认覆盖？")
        }
    }

    private var isExportDisabled: Bool {
        if fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if targetDirectory == nil { return true }
        if (selectedKind == .translation || selectedKind == .bilingual) && !hasValidTranslations { return true }
        return isExporting
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择保存目录"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    targetDirectory = url
                }
            }
        } else {
            if panel.runModal() == .OK, let url = panel.url {
                targetDirectory = url
            }
        }
    }

    private func attemptExport() {
        guard let fileURL = targetFileURL else { return }
        errorMessage = nil
        exportSuccess = false

        if FileManager.default.fileExists(atPath: fileURL.path) {
            showOverwriteAlert = true
        } else {
            performExport(allowOverwrite: false)
        }
    }

    private func performExport(allowOverwrite: Bool) {
        guard let fileURL = targetFileURL else { return }
        isExporting = true
        errorMessage = nil

        do {
            try SubtitleExporter.export(cues: cues, kind: selectedKind, to: fileURL, allowOverwrite: allowOverwrite)
            isExporting = false
            exportSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                dismiss()
            }
        } catch {
            isExporting = false
            errorMessage = error.localizedDescription
        }
    }
}
