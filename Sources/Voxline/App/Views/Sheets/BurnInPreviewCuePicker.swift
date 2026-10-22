import SwiftUI
import VoxlineCore

/// The frozen labels and playback position are independent of export progress and options.
struct BurnInPreviewCuePicker: View {
    let options: BurnInPreviewOptions
    @Binding var selection: UUID?

    var body: some View {
        #if os(macOS)
        Picker(String(localized: "预览字幕", bundle: appLocalizationBundle), selection: $selection) {
            ForEach(options.cues) { cue in
                Text(cue.label).tag(Optional(cue.id))
            }
        }
        #else
        Menu {
            Picker(String(localized: "预览字幕", bundle: appLocalizationBundle), selection: $selection) {
                ForEach(options.cues) { cue in
                    Text(cue.label)
                        .tag(Optional(cue.id))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(Color.voxlineAccent)

                let currentText = selection.flatMap { options.cuesByID[$0]?.label }
                    ?? String(localized: "选择预览字幕", bundle: appLocalizationBundle)

                Text(currentText)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        #endif
    }
}

/// A small presentation snapshot; the full task subtitle timeline remains the export input.
struct BurnInPreviewOptions {
    struct Cue: Identifiable {
        let id: UUID
        let time: Int64
        let label: String
    }

    let cues: [Cue]
    let cuesByID: [UUID: Cue]

    init(cues source: [SubtitleCue]) {
        let indices = source.count <= 50 ? Array(source.indices)
            : (0..<50).map { $0 * (source.count - 1) / 49 }
        cues = indices.map { index in
            let cue = source[index]
            #if os(macOS)
            let label = "\(SubtitleExporter.formatSRTTimestamp(milliseconds: cue.startMilliseconds)) · \(cue.sourceText.prefix(30))"
            #else
            let time = Duration.milliseconds(cue.startMilliseconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
            let label = "\(time) · \(cue.sourceText)"
            #endif
            return Cue(id: cue.id, time: cue.startMilliseconds, label: label)
        }
        cuesByID = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0) })
    }
}
