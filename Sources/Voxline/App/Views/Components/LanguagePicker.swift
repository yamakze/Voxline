import SwiftUI

struct LanguagePicker: View {
    let title: String
    @Binding var selection: String
    private static let defaultIdentifiers = Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + ["zh-Hans", "zh-Hant"]
    private static var cachedLocale = Locale.current.identifier
    private static var cachedOptions: [[String]: [(id: String, name: String)]] = [:]
    private let options: [(id: String, name: String)]

    init(title: String, selection: Binding<String>, identifiers: [String] = Self.defaultIdentifiers) {
        self.title = title
        _selection = selection
        let locale = Locale.current.identifier
        if Self.cachedLocale != locale {
            Self.cachedLocale = locale
            Self.cachedOptions.removeAll(keepingCapacity: true)
        }
        if let cached = Self.cachedOptions[identifiers] {
            options = cached
        } else {
            let localized = Set(identifiers).map { (id: $0, name: Self.name($0)) }.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            Self.cachedOptions[identifiers] = localized
            options = localized
        }
    }

    var body: some View {
        Picker(title, selection: $selection) {
            if !options.contains(where: { $0.id == selection }) {
                Text(String(localized: "未识别的语言：\(selection)", bundle: appLocalizationBundle)).tag(selection)
            }
            ForEach(options, id: \.id) { option in
                Text(option.name).tag(option.id)
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
