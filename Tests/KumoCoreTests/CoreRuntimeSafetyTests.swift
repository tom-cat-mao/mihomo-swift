import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class CoreRuntimeSafetyTests: XCTestCase {
    func testUnexpectedExitRecordsCodeFailedStateFatalAndRuntimeEvent() throws {
        let paths = makePaths()
        let core = try makeCore(in: paths, body: """
        echo 'level=fatal msg="candidate proxy is missing"'
        exit 23
        """)
        let supervisor = CoreSupervisor(
            paths: paths,
            ownerTier: .userAgent,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: CoreRecoveryPolicy(backoffs: [], stableInterval: 300)
        )

        _ = try supervisor.start(configuration: try configuration(paths: paths, corePath: core))
        let status = try waitForStatus(paths: paths) { $0.state == .failed }

        XCTAssertEqual(status.lastExit?.exitCode, 23)
        XCTAssertNil(status.lastExit?.signal)
        XCTAssertEqual(status.lastExit?.expected, false)
        XCTAssertEqual(status.ownerTier, .userAgent)
        XCTAssertTrue(status.lastExit?.message.contains("candidate proxy is missing") == true)
        XCTAssertTrue(try supervisor.recentRuntimeEvents().contains { $0.kind == "core.exit_unexpected" })
    }

    func testExpectedStopRecordsExpectedExitAndDoesNotRecover() throws {
        let paths = makePaths()
        let launches = paths.applicationSupportDirectory.appendingPathComponent("launches.txt")
        let core = try makeCore(in: paths, body: """
        echo launch >> '\(launches.path)'
        exec /bin/sleep 600
        """)
        let supervisor = CoreSupervisor(
            paths: paths,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: .testing(backoffs: [0.02, 0.02, 0.02])
        )
        _ = try supervisor.start(configuration: try configuration(paths: paths, corePath: core))
        let launchDeadline = Date().addingTimeInterval(2)
        while try lineCount(launches) == 0, Date() < launchDeadline {
            usleep(10_000)
        }

        let stopped = try supervisor.stop()
        usleep(100_000)

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.lastExit?.expected, true)
        XCTAssertEqual(try lineCount(launches), 1)
        XCTAssertFalse(try supervisor.recentRuntimeEvents().contains { $0.kind == "core.recovery_scheduled" })
    }

    func testRecoveryStopsAfterThreeAttempts() throws {
        let paths = makePaths()
        let launches = paths.applicationSupportDirectory.appendingPathComponent("launches.txt")
        let core = try makeCore(in: paths, body: """
        echo launch >> '\(launches.path)'
        exit 7
        """)
        let supervisor = CoreSupervisor(
            paths: paths,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: .testing(backoffs: [0.03, 0.03, 0.03])
        )
        _ = try supervisor.start(configuration: try configuration(paths: paths, corePath: core))

        try waitForEvent(paths: paths, supervisor: supervisor, kind: "core.recovery_exhausted")

        XCTAssertEqual(try lineCount(launches), 4, "initial launch plus three bounded recovery attempts")
        XCTAssertEqual(try CoreStateStore(paths: paths).load().state, .failed)
        let scheduled = try supervisor.recentRuntimeEvents().filter { $0.kind == "core.recovery_scheduled" }
        XCTAssertEqual(scheduled.count, 3)
    }

    func testStableFiveMinutesResetsRecoveryBudget() throws {
        let paths = makePaths()
        let core = try makeCore(in: paths, body: "exec /bin/sleep 600")
        let clock = TestClock()
        let supervisor = CoreSupervisor(
            paths: paths,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: .testing(backoffs: [0.03, 0.03]),
            now: { clock.now }
        )
        let first = try supervisor.start(configuration: try configuration(paths: paths, corePath: core))
        clock.advance(301)
        Darwin.kill(try XCTUnwrap(first.pid), SIGTERM)
        let second = try waitForStatus(paths: paths) { status in
            status.state == .running && status.pid != nil && status.pid != first.pid
        }
        Darwin.kill(try XCTUnwrap(second.pid), SIGTERM)
        let third = try waitForStatus(paths: paths) { status in
            status.state == .running && status.pid != nil && status.pid != second.pid
        }
        clock.advance(301)
        Darwin.kill(try XCTUnwrap(third.pid), SIGTERM)
        _ = try waitForStatus(paths: paths) { status in
            status.state == .running && status.pid != nil && status.pid != third.pid
        }

        let scheduled = try supervisor.recentRuntimeEvents().filter { $0.kind == "core.recovery_scheduled" }
        XCTAssertEqual(scheduled.count, 3)
        XCTAssertTrue(scheduled[0].message.contains("attempt 1 of 2"))
        XCTAssertTrue(scheduled[1].message.contains("attempt 2 of 2"))
        XCTAssertTrue(scheduled[2].message.contains("attempt 1 of 2"), "a stable later launch resets the budget")
        _ = try supervisor.stop()
        XCTAssertEqual(CoreRecoveryPolicy.default.backoffs, [2, 5, 15])
        XCTAssertEqual(CoreRecoveryPolicy.default.stableInterval, 300)
    }

    func testPreflightFailurePreservesLastGoodConfigAndNeverLaunches() throws {
        let paths = makePaths()
        let launches = paths.applicationSupportDirectory.appendingPathComponent("launches.txt")
        let core = try makeCore(in: paths, body: "echo unexpected >> '\(launches.path)'", preflight: """
        echo 'level=fatal msg="invalid rule at line 4"' >&2
        exit 1
        """)
        try paths.prepare()
        try "known-good\n".write(to: paths.runtimeConfigFile, atomically: true, encoding: .utf8)
        let supervisor = CoreSupervisor(paths: paths)

        XCTAssertThrowsError(try supervisor.start(configuration: try configuration(paths: paths, corePath: core))) { error in
            guard case .configurationValidationFailed(let message) = error as? KumoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("invalid rule at line 4"))
        }

        XCTAssertEqual(try String(contentsOf: paths.runtimeConfigFile, encoding: .utf8), "known-good\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path))
        XCTAssertFalse(try supervisor.recentRuntimeEvents().contains { $0.kind == "core.recovery_scheduled" })
    }

    func testMixedPortConflictFailsBeforePreflightOrLaunch() throws {
        let paths = makePaths()
        let listener = try allocateLocalListener()
        defer { close(listener.socket) }
        let launches = paths.applicationSupportDirectory.appendingPathComponent("launches.txt")
        let core = try makeCore(in: paths, body: "echo unexpected >> '\(launches.path)'")
        var configuration = try configuration(paths: paths, corePath: core)
        configuration.runtimeSettings.mixedPort = listener.port
        configuration.proxyPorts.mixedPort = listener.port

        XCTAssertThrowsError(try CoreSupervisor(paths: paths).start(configuration: configuration)) { error in
            guard case .portConflicts(let conflicts) = error as? KumoError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(conflicts.map(\.role), [.mixed])
            XCTAssertEqual(conflicts.first?.port, listener.port)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: launches.path))
    }

    func testStatusRejectsReusedPIDAndZombieWithoutSignalling() throws {
        let paths = makePaths()
        let startedAt = Date()
        let inspector = FakeProcessInspector(snapshot: CoreProcessSnapshot(
            startedAt: startedAt.addingTimeInterval(10),
            executablePath: "/bin/other",
            isZombie: false
        ))
        let state = CoreStateStore(paths: paths)
        try state.save(CoreStatus(
            state: .running,
            pid: 999_999,
            corePath: "/tmp/mihomo",
            processStartTime: startedAt.timeIntervalSince1970
        ))
        let supervisor = CoreSupervisor(
            paths: paths,
            processInspector: inspector,
            recoveryPolicy: CoreRecoveryPolicy(backoffs: [], stableInterval: 300)
        )

        let reused = try supervisor.status()
        XCTAssertEqual(reused.state, .failed)
        XCTAssertTrue(reused.message?.contains("reused") == true)

        inspector.snapshot = CoreProcessSnapshot(startedAt: startedAt, executablePath: "/tmp/mihomo", isZombie: true)
        try state.save(CoreStatus(
            state: .running,
            pid: 999_999,
            corePath: "/tmp/mihomo",
            processStartTime: startedAt.timeIntervalSince1970
        ))
        let zombie = try supervisor.status()
        XCTAssertEqual(zombie.state, .failed)
        XCTAssertNil(zombie.pid)
    }

    // MARK: - Hermetic fixtures

    private func makePaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func configuration(paths: KumoPaths, corePath: String) throws -> CoreLaunchConfiguration {
        let mixed = try allocateFreeLocalPort()
        var settings = CoreRuntimeSettings()
        settings.mixedPort = mixed
        return CoreLaunchConfiguration(
            corePath: corePath,
            profile: Profile(name: "Test", source: .inline, rawYAML: "proxies: []\n"),
            endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()),
            proxyPorts: ProxyPortConfiguration(mixedPort: mixed),
            runtimeSettings: settings
        )
    }

    private func makeCore(in paths: KumoPaths, body: String, preflight: String = "exit 0") throws -> String {
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        let url = paths.applicationSupportDirectory.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then
        \(preflight)
        fi
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func waitForStatus(paths: KumoPaths, predicate: (CoreStatus) -> Bool) throws -> CoreStatus {
        let store = CoreStateStore(paths: paths)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let status = try store.load()
            if predicate(status) { return status }
            usleep(20_000)
        }
        let status = try store.load()
        XCTFail("timed out waiting for status: \(status)")
        return status
    }

    private func waitForEvent(paths: KumoPaths, supervisor: CoreSupervisor, kind: String) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try supervisor.recentRuntimeEvents().contains(where: { $0.kind == kind }) { return }
            usleep(20_000)
        }
        XCTFail("timed out waiting for event \(kind)")
    }

    private func lineCount(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).count
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class FakeProcessInspector: CoreProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CoreProcessSnapshot?

    init(snapshot: CoreProcessSnapshot?) {
        stored = snapshot
    }

    var snapshot: CoreProcessSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func snapshot(pid: Int32) -> CoreProcessSnapshot? {
        snapshot
    }
}
