import Foundation

// SwiftPM CLI/tests use Bundle.module; a signed Mac app packages bundles in Resources.
#if SWIFT_PACKAGE
@usableFromInline
let appLocalizationBundle: Bundle = {
    if Bundle.main.bundleURL.pathExtension == "app" {
        guard let url = Bundle.main.url(forResource: "Voxline_VoxlineApp", withExtension: "bundle"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing packaged localization resources for VoxlineApp")
        }
        return bundle
    }
    return Bundle.module
}()
#else
private final class LocalizationBundleMarker {}
@usableFromInline
let appLocalizationBundle = Bundle(for: LocalizationBundleMarker.self)
#endif
