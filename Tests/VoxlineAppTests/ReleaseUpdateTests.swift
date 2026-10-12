import Foundation
import Synchronization
import Testing
@testable import VoxlineApp

@Suite("Release version checks", .serialized) @MainActor
struct ReleaseUpdateTests {
    @Test func semanticVersionOrderIncludesReleaseCandidatesAndNumericComponents() throws {
        let versions = try ["1.0.0-rc.2", "1.0.0-rc.10", "1.0.0", "1.0.1", "1.9.0", "1.10.0"].map(ReleaseVersion.init)
        for (earlier, later) in zip(versions, versions.dropFirst()) { #expect(earlier < later) }
        #expect(try ReleaseVersion("v1.0.0+build.2") == ReleaseVersion("1.0.0"))
    }

    @Test func newerReleaseUsesTheVersionMatchedIPAAndRetainsBilingualNotes() async throws {
        let session = client(version: "1.9.0")
        ReleaseStub.response.withLock { $0 = (200, release(version: "1.10.0")) }
        await session.check()
        guard case .available(let release) = session.state else { Issue.record("Expected a new release"); return }
        #expect(release.version == "1.10.0")
        #expect(release.ipaURL?.lastPathComponent == "Voxline-iOS-1.10.0.ipa")
        #expect(release.body == "### Added\nUpdates\n### 新增\n更新")
    }

    @Test func failedRequestCanRetryAndEmptyReleaseIsDistinctFromLatestVersion() async {
        let session = client(version: "1.0.0")
        ReleaseStub.response.withLock { $0 = (503, Data()) }
        await session.check()
        guard case .failed(let message) = session.state else { Issue.record("HTTP failure must be visible"); return }
        #expect(message.contains("503"))
        ReleaseStub.response.withLock { $0 = (200, release(version: "1.0.0")) }
        await session.check()
        #expect(session.state == .upToDate)
        ReleaseStub.response.withLock { $0 = (404, Data()) }
        await session.check()
        #expect(session.state == .noRelease)
    }

    @Test func missingIPAAndUnknownInstalledVersionAreExplicitFailures() async {
        let session = client(version: "1.0.0")
        ReleaseStub.response.withLock { $0 = (200, release(version: "2.0.0", includeIPA: false)) }
        await session.check()
        guard case .failed = session.state else { Issue.record("Missing IPA cannot be offered as an update"); return }
        let unknown = client(version: nil)
        await unknown.check()
        guard case .failed = unknown.state else { Issue.record("Missing installed version cannot default to zero"); return }
    }

    @Test(.timeLimit(.minutes(1))) func returningToPageAfterCancellationRestartsTheCheck() async throws {
        let session = client(version: "1.0.0")
        let (started, continuation) = AsyncStream<Void>.makeStream()
        ReleaseStub.started.withLock { $0 = continuation }
        ReleaseStub.delayResponse.withLock { $0 = true }
        ReleaseStub.response.withLock { $0 = (200, release(version: "1.0.0")) }
        defer {
            continuation.finish()
            ReleaseStub.started.withLock { $0 = nil }
            ReleaseStub.delayResponse.withLock { $0 = false }
            ReleaseStub.failure.withLock { $0 = nil }
        }
        let leavingPage = Task { await session.check() }
        var events = started.makeAsyncIterator()
        _ = try #require(await events.next())
        #expect(session.state == .checking)
        leavingPage.cancel()
        ReleaseStub.delayResponse.withLock { $0 = false }
        // Re-enter before the cancelled request has finished updating its state.
        await session.check()
        await leavingPage.value
        #expect(session.state == .upToDate)

        // Transport cancellation without a cancelled page task is an actual failure.
        ReleaseStub.failure.withLock { $0 = URLError(.cancelled) }
        await session.check()
        guard case .failed = session.state else { Issue.record("Active checks must expose transport failure"); return }
        ReleaseStub.failure.withLock { $0 = nil }
        await session.check()
        #expect(session.state == .upToDate)
    }

    private func client(version: String?) -> ReleaseUpdateSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseStub.self]
        return ReleaseUpdateSession(currentVersion: version, session: URLSession(configuration: configuration))
    }

    private func release(version: String, includeIPA: Bool = true) -> Data {
        let assets: [[String: String]] = includeIPA ? [
            ["name": "Other.ipa", "browser_download_url": "https://example.com/Other.ipa"],
            ["name": "Voxline-iOS-\(version).ipa", "browser_download_url": "https://example.com/Voxline-iOS-\(version).ipa"]
        ] : []
        return try! JSONSerialization.data(withJSONObject: ["tag_name": "v\(version)",
            "html_url": "https://github.com/yamakze/Voxline/releases/tag/v\(version)",
            "body": "### Added\nUpdates\n### 新增\n更新", "draft": false, "prerelease": false, "assets": assets])
    }
}

private final class ReleaseStub: URLProtocol, @unchecked Sendable {
    static let response = Mutex<(Int, Data)>((200, Data()))
    static let delayResponse = Mutex(false)
    static let started = Mutex<AsyncStream<Void>.Continuation?>(nil)
    static let failure = Mutex<URLError?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.started.withLock { $0?.yield(()) }
        if Self.delayResponse.withLock({ $0 }) { return }
        if let failure = Self.failure.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, data) = Self.response.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
