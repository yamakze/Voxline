import WhisperKit

/// Language identifiers come from the pinned transcription SDK.
public enum WhisperKitLanguages {
    public static var codes: [String] { Constants.languageCodes.sorted() }
}
