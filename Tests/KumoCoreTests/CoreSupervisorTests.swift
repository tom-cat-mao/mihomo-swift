import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class CoreSupervisorTests: XCTestCase {
    func testStartWritesPIDFileAndStopTerminatesProcess() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        let pid = try XCTUnwrap(status.pid)

        XCTAssertEqual(try String(contentsOf: paths.corePIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(pid)")

        let stopped = try supervisor.stop()

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.corePIDFile.path))
        XCTAssertFalse(isProcessAlive(pid))
    }

    func testStopUsesPIDFileWhenStatePIDIsMissing() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        let stateStore = CoreStateStore(paths: paths)

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        let pid = try XCTUnwrap(status.pid)
        try stateStore.save(CoreStatus(corePath: corePath))

        let stopped = try supervisor.stop()

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.corePIDFile.path))
        XCTAssertFalse(isProcessAlive(pid))
    }

    func testStatusRecoversRunningPIDFromPIDFileWhenStatePIDIsMissing() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        let stateStore = CoreStateStore(paths: paths)

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        let pid = try XCTUnwrap(status.pid)
        try stateStore.save(CoreStatus(corePath: corePath))

        let recovered = try supervisor.status()

        XCTAssertEqual(recovered.state, .running)
        XCTAssertEqual(recovered.pid, pid)
        _ = try supervisor.stop()
    }

    func testStartPassesControllerEndpointToMihomoArguments() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let argumentsFile = paths.applicationSupportDirectory.appendingPathComponent("core-arguments.txt")
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory, recordedArgumentsURL: argumentsFile)
        let supervisor = CoreSupervisor(paths: paths)
        let port = try allocateFreeLocalPort()

        let status = try supervisor.start(
            configuration: launchConfiguration(
                corePath: corePath,
                endpoint: ControllerEndpoint(port: port, secret: "test-secret")
            )
        )
        defer { _ = try? supervisor.stop() }

        XCTAssertEqual(status.endpoint.port, port)
        XCTAssertEqual(
            try recordedArguments(at: argumentsFile),
            [
                "-d",
                paths.workDirectory.path,
                "-ext-ctl",
                "127.0.0.1:\(port)",
                "-secret",
                "test-secret"
            ]
        )
    }

    /// `kill(pid, 0)` reports EPERM — not ESRCH — for live processes owned by
    /// another user, which is exactly the case for a root-owned core spawned
    /// by the privileged helper. pid 1 (launchd) is always live and always
    /// owned by root, from either a privileged or unprivileged test process.
    func testStatusTreatsForeignOwnedLiveProcessAsAlive() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(state: .running, pid: 1))
        let supervisor = CoreSupervisor(paths: paths)

        let recovered = try supervisor.status()

        XCTAssertEqual(recovered.state, .running)
        XCTAssertEqual(recovered.pid, 1)

        try stateStore.save(CoreStatus())
    }

    func testStartRotatesNonEmptyCoreLog() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try "previous session\n".write(to: paths.coreLogFile, atomically: true, encoding: .utf8)

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        defer { _ = try? supervisor.stop() }
        XCTAssertNotNil(status.pid)

        let logFiles = try FileManager.default.contentsOfDirectory(atPath: paths.logsDirectory.path)
        let rotatedFiles = logFiles.filter { $0.hasPrefix("core-") && $0.hasSuffix(".log") }
        XCTAssertEqual(rotatedFiles.count, 1)

        let rotatedName = try XCTUnwrap(rotatedFiles.first)
        XCTAssertNotNil(
            rotatedName.range(of: #"^core-\d{8}-\d{6}\.log$"#, options: .regularExpression),
            "unexpected rotated log name: \(rotatedName)"
        )
        XCTAssertEqual(
            try String(contentsOf: paths.logsDirectory.appendingPathComponent(rotatedName), encoding: .utf8),
            "previous session\n"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.coreLogFile.path))
        XCTAssertFalse(
            try String(contentsOf: paths.coreLogFile, encoding: .utf8).contains("previous session"),
            "the new core.log must not inherit the previous session's contents"
        )
    }

    func testStartCreatesFreshCoreLogWithoutRotating() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        defer { _ = try? supervisor.stop() }
        XCTAssertNotNil(status.pid)

        let logFiles = try FileManager.default.contentsOfDirectory(atPath: paths.logsDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.coreLogFile.path))
        XCTAssertFalse(logFiles.contains { $0.hasPrefix("core-") && $0.hasSuffix(".log") })
    }

    func testStartThrowsWhenControllerPortIsInUse() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let argumentsFile = paths.applicationSupportDirectory.appendingPathComponent("core-arguments.txt")
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory, recordedArgumentsURL: argumentsFile)
        let supervisor = CoreSupervisor(paths: paths)
        let listener = try allocateLocalListener()
        defer { close(listener.socket) }

        XCTAssertThrowsError(
            try supervisor.start(
                configuration: launchConfiguration(
                    corePath: corePath,
                    endpoint: ControllerEndpoint(port: listener.port)
                )
            )
        ) { error in
            XCTAssertEqual(error as? KumoError, KumoError.controllerPortInUse("127.0.0.1", listener.port))
        }

        usleep(200_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: argumentsFile.path),
            "no core should have been spawned while the controller port is occupied"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.corePIDFile.path))
        let stored = try CoreStateStore(paths: paths).load()
        XCTAssertNotEqual(stored.state, .running)
        XCTAssertNil(stored.pid)
    }

    /// Runtime-event bookkeeping must never turn a successful operation into a
    /// failure: with `logs/` unwritable (the root-owned `logs/` a fresh
    /// service-mode helper install leaves behind — Issue #3), recording a
    /// readiness transition still persists the state and reports success.
    func testReadinessUpdateToleratesReadOnlyLogsDirectory() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let supervisor = CoreSupervisor(paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.logsDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.logsDirectory.path)
        }

        let status = try supervisor.updateReadiness(.controllerReady, message: "Mihomo controller is ready.")

        XCTAssertEqual(status.readiness, .controllerReady)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().readiness, .controllerReady)
    }

    /// The start/stop flow appends `core.starting`, `core.started`,
    /// `core.stopped` events. None of them may fail the operation when the
    /// event log cannot be written.
    func testStartAndStopCompleteWhenRuntimeEventLogCannotBeWritten() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let supervisor = CoreSupervisor(paths: paths)
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        try "".write(to: paths.coreLogFile, atomically: true, encoding: .utf8)
        try "".write(to: paths.runtimeEventsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: paths.runtimeEventsFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.logsDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.logsDirectory.path)
        }

        let status = try supervisor.start(
            configuration: launchConfiguration(corePath: corePath, endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()))
        )
        let pid = try XCTUnwrap(status.pid)

        let stopped = try supervisor.stop()

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(isProcessAlive(pid))
    }

    private func launchConfiguration(corePath: String, endpoint: ControllerEndpoint) -> CoreLaunchConfiguration {
        CoreLaunchConfiguration(
            corePath: corePath,
            profile: Profile(
                name: "Test",
                source: .inline,
                rawYAML: """
                proxies: []
                proxy-groups:
                  - name: Proxy
                    type: select
                    proxies:
                      - DIRECT
                rules:
                  - MATCH,DIRECT
                """
            ),
            endpoint: endpoint
        )
    }

    private func makeLongRunningCore(in directory: URL, recordedArgumentsURL: URL? = nil) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        let script: String
        if let recordedArgumentsURL {
            let escapedPath = recordedArgumentsURL.path.replacingOccurrences(of: "'", with: "'\\''")
            script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(escapedPath)'
            exec /bin/sleep 600
            """
        } else {
            script = """
            #!/bin/sh
            exec /bin/sleep 600
            """
        }
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func recordedArguments(at url: URL) throws -> [String] {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
                    .split(separator: "\n")
                    .map(String.init)
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for recorded core arguments")
        return []
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
