#if os(macOS)
import SwiftUI

public struct AppearanceSettingsView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "预览", bundle: appLocalizationBundle))
                    .font(.headline)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(String(localized: "全部任务", bundle: appLocalizationBundle), systemImage: "tray.full")
                        Label(String(localized: "翻译服务", bundle: appLocalizationBundle), systemImage: "character.book.closed")
                        Label(String(localized: "云端转写", bundle: appLocalizationBundle), systemImage: "waveform")
                        Spacer()
                    }
                    .padding(16)
                    .frame(width: 160, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    Image(systemName: "captions.bubble")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 160)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))

                Text(String(localized: "外观模式", bundle: appLocalizationBundle))
                    .font(.headline)

                Picker(String(localized: "外观模式", bundle: appLocalizationBundle), selection: .constant(0)) {
                    Text(String(localized: "跟随系统", bundle: appLocalizationBundle)).tag(0)
                    Text(String(localized: "浅色", bundle: appLocalizationBundle)).tag(1)
                    Text(String(localized: "深色", bundle: appLocalizationBundle)).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(String(localized: "细节", bundle: appLocalizationBundle))
                    .font(.headline)

                VStack(spacing: 16) {
                    HStack {
                        Text(String(localized: "微染主题色", bundle: appLocalizationBundle))
                        Spacer()
                        HStack(spacing: 12) {
                            swatch(.blue, name: String(localized: "天蓝", bundle: appLocalizationBundle))
                            swatch(.indigo, name: String(localized: "靛蓝", bundle: appLocalizationBundle))
                            swatch(.green, name: String(localized: "翠色", bundle: appLocalizationBundle))
                            swatch(.red, name: String(localized: "通透红", bundle: appLocalizationBundle))
                            swatch(.gray, name: String(localized: "灰", bundle: appLocalizationBundle))
                        }
                    }
                    Divider()
                    HStack {
                        Text(String(localized: "主题色浓度", bundle: appLocalizationBundle))
                        Slider(value: .constant(0.05), in: 0...0.08)
                            .accessibilityLabel(String(localized: "主题色浓度", bundle: appLocalizationBundle))
                        Text("5%")
                            .monospacedDigit()
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            }
            .padding(24)
            .disabled(true)
        }
    }

    private func swatch(_ color: Color, name: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .accessibilityLabel(name)
    }
}
#endif
