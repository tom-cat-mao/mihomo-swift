import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoControllerHandoffTests: XCTestCase {
    func testEnablingTunHandsRunningCoreFromAgentToRootDaemon() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 4242,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))
        let recorder = TierOperationRecorder()
        let controller = makeController(
            paths: paths,
            rootReachable: true,
            agentReachable: true,
            operations: recorder.operations()
        )

        let tunStatus = try await controller.setTunEnabled(true)

        XCTAssertTrue(tunStatus.isEnabled)
        XCTAssertEqual(recorder.calls(), [
            TierCall(action: "stop", backend: .userAgent),
            TierCall(action: "start", backend: .rootService)
        ])
        let persisted = try stateStore.load()
        XCTAssertTrue(persisted.runtimeSettings?.tun?.isEnabled ?? false)
        XCTAssertEqual(persisted.serviceModeStatus?.isRunning, true)
    }

    func testEnablingTunRollsBackToAgentWhenRootStartFails() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 4242,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))
        let recorder = TierOperationRecorder()
        recorder.failStart(.rootService)
        let controller = makeController(
            paths: paths,
            rootReachable: true,
            agentReachable: true,
            operations: recorder.operations()
        )

        do {
            _ = try await controller.setTunEnabled(true)
            XCTFail("Expected the failed handoff to throw.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("Kumo agent"), "unexpected message: \(message)")
        }

        XCTAssertEqual(recorder.calls(), [
            TierCall(action: "stop", backend: .userAgent),
            TierCall(action: "start", backend: .rootService),
            TierCall(action: "start", backend: .userAgent)
        ])
        let persisted = try stateStore.load()
        XCTAssertFalse(
            persisted.runtimeSettings?.tun?.isEnabled ?? true,
            "the TUN setting must be rolled back when the handoff fails"
        )
    }

    func testDisablingTunHandsRunningCoreFromRootDaemonBackToAgent() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 4242,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))
        let recorder = TierOperationRecorder()
        let controller = makeController(
            paths: paths,
            rootReachable: true,
            agentReachable: true,
            operations: recorder.operations()
        )

        let tunStatus = try await controller.setTunEnabled(false)

        XCTAssertFalse(tunStatus.isEnabled)
        XCTAssertEqual(recorder.calls(), [
            TierCall(action: "stop", backend: .rootService),
            TierCall(action: "start", backend: .userAgent)
        ])
        let persisted = try stateStore.load()
        XCTAssertFalse(persisted.runtimeSettings?.tun?.isEnabled ?? true)
    }

    func testDisablingTunKeepsRootCoreWhenAgentStartFails() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 4242,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))
        let recorder = TierOperationRecorder()
        recorder.failStart(.userAgent)
        let controller = makeController(
            paths: paths,
            rootReachable: true,
            agentReachable: true,
            operations: recorder.operations()
        )

        do {
            _ = try await controller.setTunEnabled(false)
            XCTFail("Expected the failed handoff to throw.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("Kumo Helper"), "unexpected message: \(message)")
        }

        XCTAssertEqual(recorder.calls(), [
            TierCall(action: "stop", backend: .rootService),
            TierCall(action: "start", backend: .userAgent),
            TierCall(action: "start", backend: .rootService)
        ])
        let persisted = try stateStore.load()
        XCTAssertFalse(
            persisted.runtimeSettings?.tun?.isEnabled ?? true,
            "the disable request must survive a failed hand-back"
        )
    }

    func testEnablingTunWhileCoreIsStoppedPersistsWithoutHandoff() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(state: .stopped))
        let recorder = TierOperationRecorder()
        let controller = makeController(
            paths: paths,
            rootReachable: true,
            agentReachable: true,
            operations: recorder.operations()
        )

        let tunStatus = try await controller.setTunEnabled(true)

        XCTAssertTrue(tunStatus.isEnabled)
        XCTAssertTrue(recorder.calls().isEmpty, "a stopped core must not be handed off")
        let persisted = try stateStore.load()
        XCTAssertTrue(persisted.runtimeSettings?.tun?.isEnabled ?? false)
    }

    func testEnablingTunWithoutReachablePrivilegedTierFailsAndRollsBack() async throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 4242,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))
        let recorder = TierOperationRecorder()
        let controller = KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: .live,
            reachability: BackendReachability(rootService: { false }, userAgent: { true }),
            serviceModeStatusProvider: {
                ServiceModeStatus(
                    isInstalled: true,
                    isRunning: false,
                    isAvailable: false,
                    isCurrentProcessPrivileged: false,
                    socketPath: paths.serviceSocketFile.path,
                    message: "Kumo Helper is installed but not reachable."
                )
            },
            tierOperations: recorder.operations(),
            readinessWaiter: nil
        )

        do {
            _ = try await controller.setTunEnabled(true)
            XCTFail("Expected TUN enable to require the privileged tier.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("not reachable"), "unexpected message: \(message)")
        }

        XCTAssertTrue(recorder.calls().isEmpty, "no tier operation may run without the privileged tier")
        let persisted = try stateStore.load()
        XCTAssertFalse(persisted.runtimeSettings?.tun?.isEnabled ?? true)
        XCTAssertTrue(persisted.tunStatus?.requiresService ?? false)
    }

    // MARK: - Helpers

    private func makeController(
        paths: KumoPaths,
        rootReachable: Bool,
        agentReachable: Bool,
        operations: TierOperationsOverride
    ) -> KumoController {
        KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: .live,
            reachability: BackendReachability(
                rootService: { rootReachable },
                userAgent: { agentReachable }
            ),
            serviceModeStatusProvider: {
                ServiceModeStatus(
                    isInstalled: true,
                    isRunning: true,
                    isAvailable: true,
                    isCurrentProcessPrivileged: false,
                    socketPath: paths.serviceSocketFile.path,
                    message: "Kumo Helper is running."
                )
            },
            tierOperations: operations,
            readinessWaiter: { () async throws -> Void in }
        )
    }

    private func hermeticPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: temporaryDirectory())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// Records per-tier stop/start calls and can force configured failures, so a
/// handoff can be driven without sockets, launchd, or spawned cores.
private final class TierOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [TierCall] = []
    private var failingStarts: Set<RuntimeBackend> = []

    func calls() -> [TierCall] {
        lock.lock(); defer { lock.unlock() }
        return recordedCalls
    }

    func failStart(_ backend: RuntimeBackend) {
        lock.lock()
        failingStarts.insert(backend)
        lock.unlock()
    }

    func operations() -> TierOperationsOverride {
        TierOperationsOverride(
            stop: { [self] backend in
                record(action: "stop", backend: backend)
                return CoreStatus(state: .stopped)
            },
            start: { [self] backend in
                record(action: "start", backend: backend)
                lock.lock()
                let shouldFail = failingStarts.contains(backend)
                lock.unlock()
                if shouldFail {
                    throw KumoError.serviceUnavailable("simulated \(backend.rawValue) start failure")
                }
                return CoreStatus(state: .running, pid: 9001)
            }
        )
    }

    private func record(action: String, backend: RuntimeBackend) {
        lock.lock()
        recordedCalls.append(TierCall(action: action, backend: backend))
        lock.unlock()
    }
}

private struct TierCall: Equatable {
    var action: String
    var backend: RuntimeBackend
}
