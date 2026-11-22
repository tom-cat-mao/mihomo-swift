import Foundation
import XCTest
@testable import KumoCoreKit

final class ConfigurationTransactionClosureTests: XCTestCase {
    func testDiffAndValidateDoNotChangeAnyApplicationSupportFile() throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "proxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeStatus(paths: paths, corePath: core)
        try "last-known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let controller = makeController(paths: paths)
        let before = try applicationSupportTree(paths)

        let currentDiff = try controller.diffConfiguration()
        XCTAssertTrue(currentDiff.changed)
        XCTAssertTrue(currentDiff.diff.contains("--- a/work/config.yaml"))
        XCTAssertTrue(currentDiff.diff.contains("+++ b/work/config.yaml"))
        XCTAssertTrue(currentDiff.diff.contains("@@ -"))

        let candidateDiff = try controller.diffConfiguration(profileYAML: "candidate-marker: true\nproxies: []\n")
        XCTAssertTrue(candidateDiff.changed)
        XCTAssertTrue(candidateDiff.diff.contains("+candidate-marker: true"))
        XCTAssertEqual(candidateDiff, try controller.diffConfiguration(profileYAML: "candidate-marker: true\nproxies: []\n"))

        XCTAssertEqual(controller.validateConfiguration().valid, true)
        let invalid = controller.validateConfiguration(profileYAML: "invalid: true\n")
        XCTAssertFalse(invalid.valid)
        XCTAssertTrue(invalid.diagnostics.joined(separator: "\n").contains("invalid candidate"))

        XCTAssertEqual(try applicationSupportTree(paths), before)
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "last-known-good\n")
        XCTAssertEqual(try repository.currentProfileSummary().id, "current")
    }

    func testSuccessfulApplyCreatesRollbackPointAndInstallsCandidate() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-marker: true\nproxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        try writeStatus(paths: paths, corePath: core)
        try "last-known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let controller = makeController(paths: paths)

        let report = try await controller.applyConfiguration(profileYAML: "new-marker: true\nproxies: []\n")

        XCTAssertEqual(report.snapshotCount, 1)
        XCTAssertFalse(report.reloaded)
        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 1)
        XCTAssertEqual(try repository.profileContent(id: "current"), "new-marker: true\nproxies: []\n")
        XCTAssertTrue(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8).contains("new-marker: true"))
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.configurationRollbacksDirectory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertFalse(names.contains { $0.contains("pending") })
    }

    func testInvalidApplyRestoresEverythingAndCreatesNoSuccessfulRollbackPoint() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-marker: true\nproxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths, rejectMarker: "invalid")
        try writeStatus(paths: paths, corePath: core)
        try "last-known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let controller = makeController(paths: paths)

        do {
            _ = try await controller.applyConfiguration(profileYAML: "invalid: true\n")
            XCTFail("expected invalid apply")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }

        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 0)
        XCTAssertEqual(try repository.profileContent(id: "current"), "old-marker: true\nproxies: []\n")
        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "last-known-good\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.configurationRollbacksDirectory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".json") || $0.contains("pending") })
    }

    func testRollbackRestoresContentAndPreservesRunningProcessAndProxyIdentity() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-marker: true\nproxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        var initial = CoreStatus(
            state: .running,
            pid: 4242,
            corePath: core,
            ownerTier: .localSupervisor,
            readiness: .processLaunched,
            message: "old message",
            processStartTime: 100
        )
        initial.systemProxyEnabled = false
        try CoreStateStore(paths: paths).save(initial)
        try "last-known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = TransactionReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }

        let apply = try await controller.applyConfiguration(profileYAML: "new-marker: true\nproxies: []\n")
        XCTAssertTrue(apply.reloaded)

        var current = initial
        current.pid = 5252
        current.ownerTier = .userAgent
        current.readiness = .controllerReady
        current.message = "current observation"
        current.processStartTime = 200
        current.lastExit = CoreExit(time: Date(timeIntervalSince1970: 300), pid: 4000, expected: true, message: "keep me")
        current.systemProxyEnabled = true
        current.systemProxySettings = SystemProxySettings(host: "127.0.0.1", port: 7897)
        current.systemProxyOwnership = .takenOver
        try CoreStateStore(paths: paths).save(current)

        let rollback = try await controller.rollbackConfiguration()

        XCTAssertEqual(rollback.rollbackPointID, apply.rollbackPointID)
        XCTAssertEqual(rollback.remainingSnapshots, 0)
        XCTAssertEqual(try repository.profileContent(id: "current"), "old-marker: true\nproxies: []\n")
        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 5252)
        XCTAssertEqual(status.ownerTier, .userAgent)
        XCTAssertEqual(status.readiness, .controllerReady)
        XCTAssertEqual(status.message, "current observation")
        XCTAssertEqual(status.processStartTime, 200)
        XCTAssertEqual(status.lastExit, current.lastExit)
        XCTAssertEqual(status.systemProxyEnabled, true)
        XCTAssertEqual(status.systemProxySettings, current.systemProxySettings)
        XCTAssertEqual(status.systemProxyOwnership, .takenOver)
        XCTAssertEqual(reloads.count, 2, "apply and rollback each hot-reload the same running core")
        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 0)
    }

    func testFailedRollbackRetainsPointAndRestoresCurrentConfigurationForRetry() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "old-marker: true\nproxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        try writeStatus(paths: paths, corePath: core, state: .running)
        try "last-known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let reloads = TransactionReloadCounter()
        let controller = makeController(paths: paths) { _ in try reloads.run() }
        _ = try await controller.applyConfiguration(profileYAML: "new-marker: true\nproxies: []\n")
        try replaceCore(paths: paths, core: core, rejectMarker: "old-marker")

        do {
            _ = try await controller.rollbackConfiguration()
            XCTFail("expected rollback preflight failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rollback point was retained"))
            XCTAssertTrue(error.localizedDescription.contains("invalid candidate"))
        }

        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 1)
        XCTAssertEqual(try repository.profileContent(id: "current"), "new-marker: true\nproxies: []\n")
        let status = try CoreStateStore(paths: paths).load()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, 4242)

        try replaceCore(paths: paths, core: core, rejectMarker: nil)
        _ = try await controller.rollbackConfiguration()
        XCTAssertEqual(try repository.profileContent(id: "current"), "old-marker: true\nproxies: []\n")
        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 0)
    }

    func testRollbackUsesTheMostRecentSuccessfulApplyPoint() async throws {
        let paths = makePaths()
        let repository = ProfileRepository(paths: paths)
        _ = try repository.saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "marker: zero\nproxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        try writeStatus(paths: paths, corePath: core)
        let controller = makeController(paths: paths)
        _ = try await controller.applyConfiguration(profileYAML: "marker: one\nproxies: []\n")
        _ = try await controller.applyConfiguration(profileYAML: "marker: two\nproxies: []\n")

        let rollback = try await controller.rollbackConfiguration()

        XCTAssertEqual(rollback.remainingSnapshots, 1)
        XCTAssertEqual(try repository.profileContent(id: "current"), "marker: one\nproxies: []\n")
        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 1)
    }

    func testSuccessfulApplyHistoryIsBoundedToTenPoints() async throws {
        let paths = makePaths()
        _ = try ProfileRepository(paths: paths).saveProfile(
            Profile(name: "Current", source: .inline, rawYAML: "proxies: []\n"),
            preferredID: "current"
        )
        let core = try makeCore(paths: paths)
        try writeStatus(paths: paths, corePath: core)
        let controller = makeController(paths: paths)

        for index in 0..<12 {
            let report = try await controller.applyConfiguration(profileYAML: "marker: \(index)\nproxies: []\n")
            XCTAssertEqual(report.snapshotCount, min(index + 1, 10))
        }

        XCTAssertEqual(try ConfigurationRollbackStore(paths: paths).count(), 10)
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.configurationRollbacksDirectory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 10)
    }

    // MARK: - Fixtures

    private func makePaths() -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-config-closure-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return KumoPaths(applicationSupportDirectory: root)
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

    private func writeStatus(
        paths: KumoPaths,
        corePath: String,
        state: CoreRunState = .stopped
    ) throws {
        try paths.prepare()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: state,
            pid: state == .running ? 4242 : nil,
            corePath: corePath,
            ownerTier: state == .running ? .localSupervisor : nil,
            readiness: state == .running ? .controllerReady : nil,
            processStartTime: state == .running ? 100 : nil
        ))
    }

    private func makeCore(paths: KumoPaths, rejectMarker: String? = nil) throws -> String {
        try paths.prepare()
        let url = paths.applicationSupportDirectory.appendingPathComponent("fake-mihomo")
        try replaceCore(paths: paths, core: url.path, rejectMarker: rejectMarker)
        return url.path
    }

    private func replaceCore(paths: KumoPaths, core: String, rejectMarker: String?) throws {
        let rejection = rejectMarker.map { marker in
            "if grep -q '\(marker)' \"$5\"; then echo 'fatal: invalid candidate' >&2; exit 1; fi"
        } ?? ""
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then
          printf 'validated\\n' >> "$3/core-validation-write"
          \(rejection)
          exit 0
        fi
        exit 99
        """
        try script.write(to: URL(fileURLWithPath: core), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core)
    }

    private func applicationSupportTree(_ paths: KumoPaths) throws -> [String: String] {
        let root = paths.applicationSupportDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result[relative] = "directory"
            } else {
                result[relative] = try Data(contentsOf: url).base64EncodedString()
            }
        }
        return result
    }
}

private final class TransactionReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func run() throws {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}
