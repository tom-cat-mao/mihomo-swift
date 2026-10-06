import XCTest
@testable import KumoCoreKit

/// Subscription refresh semantics: URL dedupe for `refreshProfile(from:)`,
/// in-place refresh, and due-profile routing that must not drop Sub-Store
/// metadata.
final class ProfileRefreshTests: XCTestCase {
    private var server: LocalHTTPServer?
    private var root: URL?

    override func tearDown() {
        server?.stop()
        server = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        super.tearDown()
    }

    private func makePaths() -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.root = root
        return KumoPaths(applicationSupportDirectory: root)
    }

    private func makeServer(body: String, headers: [String: String] = [:]) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(body: body, headers: headers)
        try server.start()
        self.server = server
        return server
    }

    // MARK: - URL dedupe

    func testFindProfileByRemoteURLMatchesOnlyStoredSubscriptions() throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/a.yaml"))
        try repository.updateProfile(
            id: "a1",
            name: "A",
            remoteURL: remoteURL,
            autoUpdate: true,
            useProxy: false,
            rawYAML: "proxies: []\n"
        )

        XCTAssertEqual(try repository.findProfile(byRemoteURL: remoteURL)?.id, "a1")
        XCTAssertNil(
            try repository.findProfile(byRemoteURL: XCTUnwrap(URL(string: "https://example.com/b.yaml")))
        )
    }

    func testRefreshProfileByURLRefreshesExistingProfileWithoutDuplicate() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let server = try makeServer(body: "proxies: []\n")

        _ = try await controller.refreshProfile(from: server.url)
        let imported = try controller.profiles()
        XCTAssertEqual(imported.count, 1)
        let id = try XCTUnwrap(imported.first?.id)
        XCTAssertEqual(imported.first?.remoteURL, server.url)
        XCTAssertTrue(imported.first?.isCurrent ?? false)

        server.updateBody("proxies:\n  - name: refreshed\n")
        _ = try await controller.refreshProfile(from: server.url)

        let after = try controller.profiles()
        XCTAssertEqual(after.count, 1, "the second URL call must refresh, not duplicate")
        XCTAssertEqual(after.first?.id, id)
        XCTAssertEqual(try controller.profileContent(id: id), "proxies:\n  - name: refreshed\n")
    }

    func testRefreshProfileByURLKeepsCurrentSelectionAndAutoUpdate() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let repository = ProfileRepository(paths: paths)
        let server = try makeServer(body: "proxies: []\n")

        _ = try await controller.refreshProfile(from: server.url)
        let subscription = try XCTUnwrap(try repository.findProfile(byRemoteURL: server.url))
        let subscriptionID = subscription.id
        try repository.updateProfile(
            id: subscriptionID,
            name: subscription.name,
            remoteURL: server.url,
            autoUpdate: false,
            useProxy: false,
            rawYAML: "proxies: []\n"
        )
        try repository.saveProfile(
            Profile(name: "Other", source: .inline, rawYAML: "proxies: []\n"),
            preferredID: "other"
        )
        XCTAssertEqual(try repository.currentProfileSummary().id, "other")

        server.updateBody("proxies:\n  - name: refreshed\n")
        _ = try await controller.refreshProfile(from: server.url)

        let after = try XCTUnwrap(controller.profiles().first { $0.id == subscriptionID })
        XCTAssertFalse(after.isCurrent, "dedupe refresh must not flip the current selection")
        XCTAssertFalse(after.autoUpdate, "dedupe refresh must preserve the stored auto-update preference")
        XCTAssertEqual(try repository.currentProfileSummary().id, "other")
        XCTAssertEqual(try controller.profiles().count, 2)
    }

    func testRefreshProfileByURLWithUseProxyRequiresRunningCore() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let server = try makeServer(body: "proxies: []\n")

        do {
            _ = try await controller.refreshProfile(from: server.url, useProxy: true)
            XCTFail("expected a proxy-without-core error")
        } catch let error as KumoError {
            XCTAssertEqual(
                error,
                .invalidArguments("Start Kumo before updating this profile through the local proxy.")
            )
        }
    }

    func testRefreshProfileByIDRequiresStoredSubscription() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        try ProfileRepository(paths: paths).updateProfile(
            id: "local1",
            name: "Local",
            remoteURL: nil,
            autoUpdate: true,
            useProxy: false,
            rawYAML: "proxies: []\n"
        )

        do {
            _ = try await controller.refreshProfile(id: "local1")
            XCTFail("expected a missing-subscription error")
        } catch let error as KumoError {
            XCTAssertEqual(error, .invalidArguments("This profile does not have a remote subscription URL."))
        }
    }

    // MARK: - Due-profile routing

    func testDueRemoteProfileIDsSkipsProfilesWithoutIntervalOrAutoUpdate() throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/sub.yaml"))
        try repository.updateProfile(
            id: "manual",
            name: "Manual",
            remoteURL: remoteURL,
            autoUpdate: true,
            useProxy: false,
            rawYAML: "proxies: []\n"
        )
        try repository.updateProfile(
            id: "paused",
            name: "Paused",
            remoteURL: remoteURL,
            autoUpdate: false,
            useProxy: false,
            rawYAML: "proxies: []\n"
        )

        XCTAssertEqual(try repository.dueRemoteProfileIDs(now: Date().addingTimeInterval(7_200)), [])
    }

    func testRefreshDueProfilesRefreshesPlainRemoteProfileInPlace() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let repository = ProfileRepository(paths: paths)
        let server = try makeServer(body: "proxies: []\n", headers: ["profile-update-interval": "1"])

        _ = try await repository.saveRemoteProfile(
            from: server.url,
            autoUpdate: true,
            preferredID: "plain1",
            makeCurrent: true
        )

        server.updateBody("proxies:\n  - name: refreshed\n")
        let refreshed = try await controller.refreshDueProfiles(now: Date().addingTimeInterval(7_200))

        XCTAssertEqual(refreshed.map(\.id), ["plain1"])
        let after = try XCTUnwrap(repository.listProfiles().first { $0.id == "plain1" })
        XCTAssertEqual(after.kind, .remote)
        XCTAssertEqual(after.remoteURL, server.url)
        XCTAssertTrue(after.autoUpdate)
        XCTAssertTrue(after.isCurrent, "due refresh keeps the current selection")
        XCTAssertEqual(try repository.profileContent(id: "plain1"), "proxies:\n  - name: refreshed\n")
    }

    func testRefreshDueProfilesPreservesSubStoreMetadata() async throws {
        let paths = makePaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let repository = ProfileRepository(paths: paths)
        let server = try makeServer(body: "proxies: []\n", headers: ["profile-update-interval": "1"])

        _ = try await repository.saveSubStoreProfile(
            name: "Sub",
            subStorePath: server.url.absoluteString,
            downloadURL: server.url,
            autoUpdate: true,
            preferredID: "sub1",
            makeCurrent: false
        )
        XCTAssertTrue(try XCTUnwrap(repository.listProfiles().first { $0.id == "sub1" }).isSubStoreManaged)

        server.updateBody("proxies:\n  - name: refreshed\n")
        let refreshed = try await controller.refreshDueProfiles(now: Date().addingTimeInterval(7_200))

        XCTAssertEqual(refreshed.map(\.id), ["sub1"])
        let after = try XCTUnwrap(repository.listProfiles().first { $0.id == "sub1" })
        XCTAssertTrue(after.isSubStoreManaged, "a due refresh must not drop Sub-Store ownership")
        XCTAssertEqual(after.subStorePath, server.url.absoluteString)
        XCTAssertTrue(after.autoUpdate)
        XCTAssertEqual(try repository.profileContent(id: "sub1"), "proxies:\n  - name: refreshed\n")
    }
}
