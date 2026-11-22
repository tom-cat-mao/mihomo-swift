import Foundation
import XCTest
@testable import KumoCoreKit

final class ConfigurationTransactionTests: XCTestCase {
    private var server: LocalHTTPServer?

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    func testActivateProfilePreflightFailureRestoresCurrentIDAndLastGoodConfig() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(Profile(name: "Old", source: .inline, rawYAML: "proxies: []\n"), preferredID: "old")
        _ = try repository.saveProfile(Profile(name: "New", source: .inline, rawYAML: "invalid: true\n"), preferredID: "new", makeCurrent: false)
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let controller = makeController(paths: paths)

        do {
            try await controller.activateProfile(id: "new")
            XCTFail("expected preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }

        XCTAssertEqual(try repository.currentProfileSummary().id, "old")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        XCTAssertEqual(try CoreStateStore(paths: paths).load().state, .running)
    }

    func testHotReloadFailureRestoresProfileAndConfigWithoutStoppingCore() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(Profile(name: "Old", source: .inline, rawYAML: "proxies: []\n"), preferredID: "old")
        _ = try repository.saveProfile(Profile(name: "New", source: .inline, rawYAML: "new-setting: true\n"), preferredID: "new", makeCurrent: false)
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter(error: KumoError.controllerResponse(400, "fatal: bad candidate"))
        let controller = makeController(paths: paths) { _ in
            try reloads.run()
        }

        do {
            try await controller.activateProfile(id: "new")
            XCTFail("expected hot reload failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bad candidate"))
        }

        XCTAssertEqual(try repository.currentProfileSummary().id, "old")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(reloads.count, 2, "the previous file is offered again after the failed candidate")
    }

    func testOverrideFailureRestoresContentAndLastGoodConfig() async throws {
        let paths = makePaths()
        let repository = OverrideRepository(paths: paths)
        let item = try repository.addLocalOverride(name: "Rules", format: .yaml, content: "old-setting: true\n")
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter(error: KumoError.controllerResponse(500, "reload rejected"))
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        do {
            try await controller.changeOverride(item, content: "new-setting: true\n")
            XCTFail("expected hot reload failure")
        } catch {}

        XCTAssertEqual(try repository.content(id: item.id), "old-setting: true\n")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        XCTAssertEqual(try CoreStateStore(paths: paths).load().state, .running)
    }

    func testSuccessfulOverrideMutationUsesHotReload() async throws {
        let paths = makePaths()
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        _ = try await controller.createLocalOverride(name: "New", format: .yaml, content: "success-marker: true\n")

        XCTAssertEqual(reloads.count, 1)
        let config = try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8)
        XCTAssertTrue(config.contains("success-marker"))
        XCTAssertEqual(try CoreStateStore(paths: paths).load().state, .running)
    }

    func testRestartPreflightFailureDoesNotStopRunningCore() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "Bad", source: .inline, rawYAML: "invalid: true\n"),
            preferredID: "bad"
        )
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeRunningState(paths: paths, corePath: core)
        let controller = makeController(paths: paths)

        XCTAssertThrowsError(try controller.restart())

        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 4242)
    }

    func testSubscriptionRefreshFailureRestoresDownloadedContentAndCurrentSelection() async throws {
        let paths = makePaths()
        let server = try LocalHTTPServer(body: "proxies: []\n")
        try server.start()
        self.server = server
        let repository = ProfileRepository(paths: paths)
        _ = try await repository.saveRemoteProfile(from: server.url, preferredID: "subscription", makeCurrent: true)
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter(error: KumoError.controllerResponse(400, "bad subscription"))
        let controller = makeController(paths: paths) { _ in try reloads.run() }
        server.updateBody("new-subscription-content: true\n")

        do {
            _ = try await controller.refreshProfile(id: "subscription")
            XCTFail("expected hot reload failure")
        } catch {}

        XCTAssertEqual(try repository.profileContent(id: "subscription"), "proxies: []\n")
        XCTAssertEqual(try repository.currentProfileSummary().id, "subscription")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
    }

    func testCurrentProfileEditPreflightFailurePreservesRunningProcessAndContent() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-setting: true\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        do {
            _ = try await controller.updateProfile(
                id: "current",
                name: "Current",
                remoteURL: nil,
                autoUpdate: false,
                useProxy: false,
                rawYAML: "invalid: true\n"
            )
            XCTFail("expected preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }

        XCTAssertEqual(try repository.profileContent(id: "current"), "old-setting: true\n")
        XCTAssertEqual(try repository.currentProfileSummary().id, "current")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(status.readiness, .controllerReady)
        XCTAssertEqual(reloads.count, 0)
    }

    func testCurrentProfileEditUsesHotReloadAndMetadataOnlyEditDoesNotReload() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-setting: true\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        _ = try await controller.updateProfile(
            id: "current",
            name: "Current",
            remoteURL: nil,
            autoUpdate: false,
            useProxy: false,
            rawYAML: "new-setting: true\n"
        )

        XCTAssertEqual(reloads.count, 1)
        XCTAssertTrue(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8).contains("new-setting"))
        XCTAssertEqual(try CoreStateStore(paths: paths).load().pid, 4242)

        let renamed = try await controller.updateProfile(
            id: "current",
            name: "Renamed",
            remoteURL: nil,
            autoUpdate: true,
            useProxy: true,
            rawYAML: "new-setting: true\n"
        )
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(reloads.count, 1, "metadata-only edits must not reload an unchanged YAML document")
    }

    func testNonCurrentProfileEditAndDeleteDoNotReload() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(Profile(name: "Current", source: .inline, rawYAML: "proxies: []\n"), preferredID: "current")
        _ = try repository.saveProfile(Profile(name: "Other", source: .inline, rawYAML: "proxies: []\n"), preferredID: "other", makeCurrent: false)
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        _ = try await controller.updateProfile(
            id: "other",
            name: "Other",
            remoteURL: nil,
            autoUpdate: false,
            useProxy: false,
            rawYAML: "other-setting: true\n"
        )
        let deletedCurrent = try await controller.deleteProfile(id: "other")

        XCTAssertFalse(deletedCurrent)
        XCTAssertEqual(reloads.count, 0)
        XCTAssertEqual(try repository.currentProfileSummary().id, "current")
        XCTAssertEqual(try CoreStateStore(paths: paths).load().pid, 4242)
    }

    func testDeleteCurrentProfileUsesHotReloadForNextProfile() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(Profile(name: "Current", source: .inline, rawYAML: "old-setting: true\n"), preferredID: "current")
        _ = try repository.saveProfile(Profile(name: "Next", source: .inline, rawYAML: "next-setting: true\n"), preferredID: "next", makeCurrent: false)
        let core = try makeCore(paths: paths)
        try writeRunningState(paths: paths, corePath: core)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        let deletedCurrent = try await controller.deleteProfile(id: "current")

        XCTAssertTrue(deletedCurrent)
        XCTAssertEqual(reloads.count, 1)
        XCTAssertEqual(try repository.currentProfileSummary().id, "next")
        XCTAssertFalse(try repository.listProfiles().contains(where: { $0.id == "current" }))
        XCTAssertTrue(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8).contains("next-setting"))
        XCTAssertEqual(try CoreStateStore(paths: paths).load().pid, 4242)
    }

    func testDeleteCurrentProfilePreflightFailureRestoresDeletedProfileAndSelection() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(Profile(name: "Current", source: .inline, rawYAML: "old-setting: true\n"), preferredID: "current")
        _ = try repository.saveProfile(Profile(name: "Next", source: .inline, rawYAML: "invalid: true\n"), preferredID: "next", makeCurrent: false)
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeRunningState(paths: paths, corePath: core)
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = ReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        do {
            _ = try await controller.deleteProfile(id: "current")
            XCTFail("expected preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }

        XCTAssertEqual(try repository.currentProfileSummary().id, "current")
        XCTAssertEqual(try repository.profileContent(id: "current"), "old-setting: true\n")
        XCTAssertTrue(try repository.listProfiles().contains(where: { $0.id == "next" }))
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(reloads.count, 0)
    }

    // MARK: - Fixtures

    private func makePaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func makeController(
        paths: KumoPaths,
        reloader: (@Sendable (String) async throws -> Void)? = nil
    ) -> KumoController {
        KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: .live,
            reachability: nil,
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil,
            configurationReloader: reloader
        )
    }

    private func writeRunningState(paths: KumoPaths, corePath: String) throws {
        try paths.prepare()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: 4242,
            corePath: corePath,
            ownerTier: .localSupervisor,
            readiness: .controllerReady
        ))
    }

    private func makeCore(paths: KumoPaths, rejectMarker: String? = nil) throws -> String {
        try paths.prepare()
        let url = paths.applicationSupportDirectory.appendingPathComponent("fake-mihomo")
        let rejection = rejectMarker.map { marker in
            "if grep -q '\(marker)' \"$5\"; then echo 'fatal: invalid candidate' >&2; exit 1; fi"
        } ?? ""
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then
          \(rejection)
          exit 0
        fi
        exit 99
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func run() throws {
        lock.lock()
        storedCount += 1
        lock.unlock()
        if let error { throw error }
    }
}
