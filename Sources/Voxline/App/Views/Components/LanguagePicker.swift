import SwiftUI

struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    var identifiers: [String] = Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + ["zh-Hans", "zh-Hant"]

    var body: some View {
        Picker(title, selection: $selection) {
            if !identifiers.contains(selection) {
                Text(String(localized: "未识别的语言：\(selection)", bundle: appLocalizationBundle)).tag(selection)
            }
            ForEach(Array(Set(identifiers)).sorted {
                Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending
            }, id: \.self) { identifier in
                Text(Self.name(identifier)).tag(identifier)
            }
        }
    }

    static func name(_ identifier: String) -> String {
        switch identifier {
        case "zh-Hans": String(localized: "简体中文", bundle: appLocalizationBundle)
        case "zh-Hant": String(localized: "繁体中文", bundle: appLocalizationBundle)
        default: Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        }
    }
}
