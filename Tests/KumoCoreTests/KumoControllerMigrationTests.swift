import Foundation
import XCTest
@testable import KumoCoreKit

/// Two-tier detection and `migrateCoreToUserAgent()` tests. Tier handoffs are
/// driven through the `TierOperationsOverride` seam (T1a) so stop/start
/// routing and rollback are proven without sockets, launchd, or spawns; the
/// installed-agent state comes from a hermetic `LaunchAgents` directory.
final class KumoControllerMigrationTests: XCTestCase {
    // MARK: - Dual-tier detection

    func testInstallStateReportsEveryTierCombination() {
        let cases: [(rootInstalled: Bool, agentInstalled: Bool, expected: TierInstallState.InstallState)] = [
            (false, false, .none),
            (true, false, .rootOnly),
            (false, true, .userOnly),
            (true, true, .dual)
        ]

        for testCase in cases {
            let fixture = makeFixture(
                rootInstalled: testCase.rootInstalled,
                agentInstalled: testCase.agentInstalled
            )
            XCTAssertEqual(
                fixture.controller.tierInstallState().installState,
                testCase.expected,
                "root=\(testCase.rootInstalled) agent=\(testCase.agentInstalled)"
            )
        }
    }

    func testCoreOwnerFollowsRouting() throws {
        // TUN off, agent reachable: the agent is the owner.
        let agentFirst = makeFixture(
            rootInstalled: true,
            agentInstalled: true,
            rootReachable: true,
            agentReachable: true
        )
        XCTAssertEqual(agentFirst.controller.tierInstallState().coreOwner, .userAgent)

        // TUN off, agent unreachable, root reachable: pre-agent root ownership.
        let rootOnly = makeFixture(
            rootInstalled: true,
            agentInstalled: true,
            rootReachable: true,
            agentReachable: false
        )
        XCTAssertEqual(rootOnly.controller.tierInstallState().coreOwner, .rootService)

        // TUN off, no socket tier reachable: the local supervisor.
        let local = makeFixture(rootInstalled: false, agentInstalled: false)
        XCTAssertEqual(local.controller.tierInstallState().coreOwner, .localSupervisor)

        // TUN on, root reachable: the root daemon is always the owner.
        let tunRoot = makeFixture(
            rootInstalled: true,
            agentInstalled: true,
            rootReachable: true,
            agentReachable: true,
            tunEnabled: true
        )
        let tunState = tunRoot.controller.tierInstallState()
        XCTAssertEqual(tunState.coreOwner, .rootService)
        XCTAssertTrue(tunState.tunEnabled)

        // TUN on, no privileged executor: routing refuses to pick a user tier.
        let tunUnavailable = makeFixture(
            rootInstalled: true,
            agentInstalled: true,
            rootReachable: false,
            agentReachable: true,
            tunEnabled: true
        )
        let unavailable = tunUnavailable.controller.tierInstallState()
        XCTAssertEqual(unavailable.coreOwner, .unavailable)
        XCTAssertEqual(unavailable.ownerUnavailableReason != nil, true)
    }

    // MARK: - Migration guards

    func testMigrationRefusesWhileTunIsEnabled() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, tunEnabled: true)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))

        do {
            _ = try fixture.controller.migrateCoreToUserAgent()
            XCTFail("Expected the TUN guard to refuse the migration.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("TUN is enabled"), "unexpected message: \(message)")
        }

        XCTAssertTrue(fixture.recorder.calls().isEmpty, "a refused migration must not touch any tier")
    }

    func testMigrationRefusesWhenAgentIsNotInstalled() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: false)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        ))

        do {
            _ = try fixture.controller.migrateCoreToUserAgent()
            XCTFail("Expected the missing-agent guard to refuse the migration.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("not installed"), "unexpected message: \(message)")
        }

        XCTAssertTrue(fixture.recorder.calls().isEmpty, "a refused migration must not touch any tier")
    }

    func testMigrationPlanReportsGuardsWithoutThrowing() throws {
        let fixture = makeFixture(
            rootInstalled: true,
            agentInstalled: false,
            rootReachable: true,
            agentReachable: false,
            tunEnabled: true
        )

        let plan = try fixture.controller.coreMigrationPlan()

        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.blockers.count, 2, "both the TUN and missing-agent guards must be reported")
        XCTAssertTrue(plan.blockers[0].contains("TUN is enabled"))
        XCTAssertTrue(plan.blockers[1].contains("not installed"))
    }

    func testMigrationPlanDoesNotRefuseWhileTunIsDisabled() throws {
        // Regression guard for the production starting state: TUN is the only
        // thing that pins the core to the root daemon.
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: false)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))

        let plan = try fixture.controller.coreMigrationPlan()

        XCTAssertEqual(plan.action, .handoff)
        XCTAssertTrue(plan.blockers.isEmpty)
        XCTAssertEqual(plan.tier.coreOwner, .rootService)
    }

    // MARK: - Migration outcomes

    func testMigrationHandsRootOwnedCoreToAgent() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: false)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))

        let result = try fixture.controller.migrateCoreToUserAgent()

        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.plan.tier.coreOwner, .rootService)
        XCTAssertEqual(fixture.recorder.calls(), [
            TierCall(action: "stop", backend: .rootService),
            TierCall(action: "start", backend: .userAgent)
        ])
        XCTAssertEqual(result.coreState, .running)
    }

    func testMigrationRollsBackToRootWhenAgentStartFails() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: false)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))
        fixture.recorder.failStart(.userAgent)

        do {
            _ = try fixture.controller.migrateCoreToUserAgent()
            XCTFail("Expected the failed handoff to throw.")
        } catch let error as KumoError {
            guard case .serviceUnavailable(let message) = error else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("Kumo Helper"), "the rollback must restore the root-owned core: \(message)")
        }

        XCTAssertEqual(fixture.recorder.calls(), [
            TierCall(action: "stop", backend: .rootService),
            TierCall(action: "start", backend: .userAgent),
            TierCall(action: "start", backend: .rootService)
        ])
    }

    func testMigrationIsIdempotentAfterHandoff() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: false)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))

        _ = try fixture.controller.migrateCoreToUserAgent()
        XCTAssertEqual(fixture.recorder.calls().count, 2)

        // The agent now owns a running core, so its reachability probe answers
        // and routing selects the agent.
        fixture.agentReachable.value = true
        let second = try fixture.controller.migrateCoreToUserAgent()

        XCTAssertFalse(second.migrated)
        XCTAssertEqual(second.plan.action, .none)
        XCTAssertEqual(second.plan.reason?.contains("already owns"), true)
        XCTAssertEqual(fixture.recorder.calls().count, 2, "a repeated migration must not touch any tier")
    }

    func testMigrationIsNoOpWhenCoreIsStopped() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: false)
        try fixture.stateStore.save(CoreStatus(state: .stopped))

        let result = try fixture.controller.migrateCoreToUserAgent()

        XCTAssertFalse(result.migrated)
        XCTAssertEqual(result.plan.reason?.contains("No Mihomo core is running"), true)
        XCTAssertTrue(fixture.recorder.calls().isEmpty)
    }

    func testMigrationIsNoOpWhenAgentAlreadyOwnsCore() throws {
        let fixture = makeFixture(rootInstalled: true, agentInstalled: true, rootReachable: true, agentReachable: true)
        try fixture.stateStore.save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        ))

        let result = try fixture.controller.migrateCoreToUserAgent()

        XCTAssertFalse(result.migrated)
        XCTAssertEqual(result.plan.tier.coreOwner, .userAgent)
        XCTAssertEqual(result.plan.reason?.contains("already owns"), true)
        XCTAssertTrue(fixture.recorder.calls().isEmpty)
    }

    // MARK: - Helpers

    private struct Fixture {
        var controller: KumoController
        var recorder: MigrationTierRecorder
        var stateStore: CoreStateStore
        var agentReachable: ReachabilityBox
    }

    private func makeFixture(
        rootInstalled: Bool,
        agentInstalled: Bool,
        rootReachable: Bool? = nil,
        agentReachable: Bool? = nil,
        tunEnabled: Bool = false
    ) -> Fixture {
        let paths = hermeticPaths()
        if agentInstalled {
            try? FileManager.default.createDirectory(
                at: paths.launchAgentsDirectory,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: paths.userAgentPlistFile.path, contents: Data())
        }

        let rootProbe = rootReachable ?? rootInstalled
        let agentProbe = ReachabilityBox(value: agentReachable ?? agentInstalled)
        let recorder = MigrationTierRecorder()
        let stateStore = CoreStateStore(paths: paths)
        if tunEnabled {
            try? stateStore.save(CoreStatus(
                runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
            ))
        }

        let controller = KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: .live,
            reachability: BackendReachability(
                rootService: { rootProbe },
                userAgent: { agentProbe.value }
            ),
            serviceModeStatusProvider: {
                ServiceModeStatus(
                    isInstalled: rootInstalled,
                    isRunning: rootReachable ?? rootInstalled,
                    isAvailable: rootReachable ?? rootInstalled,
                    isCurrentProcessPrivileged: false,
                    socketPath: paths.serviceSocketFile.path,
                    message: rootInstalled ? "Kumo Helper is installed." : nil
                )
            },
            tierOperations: recorder.operations(),
            readinessWaiter: { () async throws -> Void in }
        )
        return Fixture(
            controller: controller,
            recorder: recorder,
            stateStore: stateStore,
            agentReachable: agentProbe
        )
    }

    private func hermeticPaths() -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return KumoPaths(
            applicationSupportDirectory: root,
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }
}

/// Mutable reachability probe so a test can flip the agent tier "reachable"
/// after a successful handoff, mirroring the agent becoming resident.
private final class ReachabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(value: Bool) {
        self.storedValue = value
    }

    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

/// Records per-tier stop/start calls and can force configured failures (the
/// T1a seam pattern), so migration handoff and rollback run without sockets.
private final class MigrationTierRecorder: @unchecked Sendable {
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
