import Foundation
import Observation

struct PublishedRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease, assets
    }
    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    var ipaURL: URL? { assets.first { $0.name == "Voxline-iOS-\(version).ipa" }?.browserDownloadURL }
}

enum ReleaseUpdateError: LocalizedError {
    case invalidVersion, invalidResponse, unpublishedRelease, missingIPA
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidVersion: String(localized: "版本信息无效。", bundle: appLocalizationBundle)
        case .invalidResponse: String(localized: "更新服务响应无效。", bundle: appLocalizationBundle)
        case .unpublishedRelease: String(localized: "暂无可用更新", bundle: appLocalizationBundle)
        case .missingIPA: String(localized: "此版本未提供 IPA。", bundle: appLocalizationBundle)
        case .httpStatus(let status): String(localized: "更新检查失败（HTTP \(status)）。", bundle: appLocalizationBundle)
        }
    }
}

@Observable @MainActor
final class ReleaseUpdateSession {
    enum State: Equatable {
        case idle, checking, upToDate, noRelease
        case available(PublishedRelease), failed(String)
    }
    private(set) var state: State = .idle
    let currentVersion: String?
    let releasesURL = URL(string: "https://github.com/yamakze/Voxline/releases/latest")!
    private let session: URLSession
    private let endpoint: URL
    private var requestTask: Task<Void, Never>?

    init(currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         session: URLSession = .shared,
         endpoint: URL = URL(string: "https://api.github.com/repos/yamakze/Voxline/releases/latest")!) {
        self.currentVersion = currentVersion
        self.session = session
        self.endpoint = endpoint
    }

    func check() async {
        if let requestTask {
            await requestTask.value
            if state == .idle, !Task.isCancelled { await check() }
            return
        }
        guard !Task.isCancelled else { return }
        state = .checking
        let request = Task { await fetchLatestRelease() }
        requestTask = request
        await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func fetchLatestRelease() async {
        defer { requestTask = nil }
        do {
            try Task.checkCancellation()
            guard let currentVersion else { throw ReleaseUpdateError.invalidVersion }
            let installed = try ReleaseVersion(currentVersion)
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Voxline/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ReleaseUpdateError.invalidResponse }
            if response.statusCode == 404 { state = .noRelease; return }
            guard response.statusCode == 200 else { throw ReleaseUpdateError.httpStatus(response.statusCode) }
            let release = try JSONDecoder().decode(PublishedRelease.self, from: data)
            guard !release.draft, !release.prerelease else { throw ReleaseUpdateError.unpublishedRelease }
            if try ReleaseVersion(release.tagName) <= installed { state = .upToDate; return }
            guard release.ipaURL != nil else { throw ReleaseUpdateError.missingIPA }
            state = .available(release)
        } catch {
            state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
        }
    }
}
