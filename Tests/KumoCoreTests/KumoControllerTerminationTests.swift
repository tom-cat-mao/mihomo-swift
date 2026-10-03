import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoControllerTerminationTests: XCTestCase {
    func testKeepCoreAliveLeavesRunningCoreAndSystemProxyUntouched() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        // Spawn on an ephemeral controller port: start() refuses to launch when
        // the configured port is already serving (9097 may hold a real core).
        try stateStore.save(CoreStatus(
            endpoint: ControllerEndpoint(port: try allocateFreeLocalPort()),
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Wi-Fi")
        ))
        let recorder = TerminationCommandRecorder()
        let controller = KumoController(paths: paths, systemProxyCommandRunner: recorder.makeRunner())
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let running = try controller.start(corePath: corePath)
        let pid = try XCTUnwrap(running.pid)

        let result = await controller.prepareForAppTermination(policy: .keepCoreAlive)

        XCTAssertEqual(result.status.state, .running)
        XCTAssertEqual(result.status.pid, pid)
        XCTAssertTrue(isProcessAlive(pid), "keepCoreAlive must not stop the core")
        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
        XCTAssertTrue(
            recorder.runArguments().isEmpty,
            "keepCoreAlive must not touch the system proxy; ran: \(recorder.runArguments())"
        )

        _ = try? controller.stop()
    }

    func testStopRuntimePolicyStopsTheRunningCore() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(endpoint: ControllerEndpoint(port: try allocateFreeLocalPort())))
        let controller = KumoController(paths: paths)
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        let running = try controller.start(corePath: corePath)
        let pid = try XCTUnwrap(running.pid)

        let result = await controller.prepareForAppTermination(policy: .stopRuntime)

        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertNil(result.status.pid)
        XCTAssertFalse(isProcessAlive(pid))
        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
    }

    func testStopRuntimeRemainsTheDefaultPolicy() async {
        let paths = hermeticPaths()
        let controller = KumoController(paths: paths)

        let result = await controller.prepareForAppTermination()

        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
    }

    func testKeepCoreAliveIsNoOpWhenAlreadyStopped() async {
        let paths = hermeticPaths()
        let recorder = TerminationCommandRecorder()
        let controller = KumoController(paths: paths, systemProxyCommandRunner: recorder.makeRunner())

        let result = await controller.prepareForAppTermination(policy: .keepCoreAlive)

        XCTAssertEqual(result.status.state, .stopped)
        XCTAssertNil(result.status.pid)
        XCTAssertTrue(result.diagnostics.isEmpty, "unexpected diagnostics: \(result.diagnostics)")
        XCTAssertTrue(recorder.runArguments().isEmpty, "no commands should have run")
    }

    // MARK: - Helpers

    private func makeLongRunningCore(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-mihomo")
        try """
        #!/bin/sh
        exec /bin/sleep 600
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }

    private func hermeticPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
}

/// Records every `SystemProxyCommandRunner` invocation so a termination policy
/// can prove it did not touch the proxy.
private final class TerminationCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [ShellCommand] = []

    func runArguments() -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return commands.map(\.arguments)
    }

    func makeRunner() -> SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { [self] command in
                lock.lock()
                commands.append(command)
                lock.unlock()
            },
            captureOutput: { _ in "" }
        )
    }
}
