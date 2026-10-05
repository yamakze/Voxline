import SwiftUI

struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    var identifiers: [String] = Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + ["zh-Hans", "zh-Hant"]

    var body: some View {
        Picker(title, selection: $selection) {
            if !identifiers.contains(selection) {
                Text("未识别的语言：\(selection)").tag(selection)
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
        case "zh-Hans": "简体中文"
        case "zh-Hant": "繁体中文"
        default: Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        }
    }
}
