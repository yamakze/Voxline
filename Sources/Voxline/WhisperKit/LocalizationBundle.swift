import Foundation

// SwiftPM CLI/tests use Bundle.module; a signed Mac app packages bundles in Resources.
#if SWIFT_PACKAGE
@usableFromInline
let voxlineLocalizationBundle: Bundle = {
    if Bundle.main.bundleURL.pathExtension == "app" {
        guard let url = Bundle.main.url(forResource: "Voxline_VoxlineWhisperKit", withExtension: "bundle"),
              let bundle = Bundle(url: url) else {
            preconditionFailure("Missing packaged localization resources for VoxlineWhisperKit")
        }
        return bundle
    }
    return Bundle.module
}()
#else
private final class LocalizationBundleMarker {}
@usableFromInline
let voxlineLocalizationBundle = Bundle(for: LocalizationBundleMarker.self)
#endif
