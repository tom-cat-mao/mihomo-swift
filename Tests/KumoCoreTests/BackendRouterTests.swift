import Foundation
import XCTest
@testable import KumoCoreKit

final class BackendRouterTests: XCTestCase {
    func testTunEnabledPrefersRootDaemonEvenWhenAgentIsReachable() {
        let router = makeRouter(rootReachable: true, agentReachable: true)
        XCTAssertEqual(router.decideCoreBackend(tunEnabled: true), .backend(.rootService))
    }

    func testTunEnabledWithoutRootDaemonAndWithoutPrivilegeIsUnavailable() {
        let router = makeRouter(rootReachable: false, agentReachable: true)
        let decision = router.decideCoreBackend(tunEnabled: true)

        XCTAssertNil(decision.backend)
        let reason = decision.unavailableReason ?? ""
        XCTAssertTrue(reason.contains("TUN"), "unexpected reason: \(reason)")
        XCTAssertTrue(reason.contains("Helper"), "unexpected reason: \(reason)")
    }

    func testTunEnabledFallsBackToPrivilegedLocalProcess() {
        let router = BackendRouter(reachability: BackendReachability(
            rootService: { false },
            userAgent: { true },
            privilegedLocalProcess: { true }
        ))
        XCTAssertEqual(router.decideCoreBackend(tunEnabled: true), .backend(.localSupervisor))
    }

    func testTunDisabledPrefersUserAgentOverRootDaemonAndLocal() {
        let router = BackendRouter(reachability: BackendReachability(
            rootService: { true },
            userAgent: { true },
            privilegedLocalProcess: { true }
        ))
        XCTAssertEqual(router.decideCoreBackend(tunEnabled: false), .backend(.userAgent))
    }

    func testTunDisabledWithUnreachableAgentFallsBackToLocalSupervisor() {
        let router = makeRouter(rootReachable: true, agentReachable: false)
        XCTAssertEqual(router.decideCoreBackend(tunEnabled: false), .backend(.localSupervisor))
    }

    func testServiceBackendDisabledShortCircuitsToLocalForEveryTunState() {
        let router = BackendRouter(
            reachability: BackendReachability(
                rootService: { true },
                userAgent: { true },
                privilegedLocalProcess: { true }
            ),
            allowsServiceBackend: false
        )

        XCTAssertEqual(router.decideCoreBackend(tunEnabled: true), .backend(.localSupervisor))
        XCTAssertEqual(router.decideCoreBackend(tunEnabled: false), .backend(.localSupervisor))
        XCTAssertEqual(router.privilegedBackend(), .localSupervisor)
    }

    func testPrivilegedBackendUsesRootDaemonOnlyWhenReachable() {
        XCTAssertEqual(makeRouter(rootReachable: true, agentReachable: false).privilegedBackend(), .rootService)
        XCTAssertEqual(makeRouter(rootReachable: false, agentReachable: true).privilegedBackend(), .localSupervisor)
    }

    func testMutationsFailFastWhenTunOnWithoutReachablePrivilegedTier() throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 123,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))
        let controller = makeController(
            paths: paths,
            reachability: BackendReachability(rootService: { false }, userAgent: { true })
        )

        XCTAssertThrowsError(try controller.stop()) { error in
            guard case .serviceUnavailable(let message) = error as? KumoError else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("TUN"), "unexpected message: \(message)")
        }
        XCTAssertThrowsError(try controller.start()) { error in
            guard case .serviceUnavailable = error as? KumoError else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
        }
        XCTAssertThrowsError(try controller.restart()) { error in
            guard case .serviceUnavailable = error as? KumoError else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
        }
    }

    func testStatusStillReadsSharedStateWhenTunTierIsUnreachable() throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        let pid = Int32(getpid())
        try stateStore.save(CoreStatus(
            state: .running,
            pid: pid,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: true))
        ))
        let controller = makeController(
            paths: paths,
            reachability: BackendReachability(rootService: { false }, userAgent: { true })
        )

        let status = try controller.status()

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.pid, pid)
    }

    // MARK: - Helpers

    private func makeRouter(rootReachable: Bool, agentReachable: Bool) -> BackendRouter {
        BackendRouter(reachability: BackendReachability(
            rootService: { rootReachable },
            userAgent: { agentReachable }
        ))
    }

    private func makeController(paths: KumoPaths, reachability: BackendReachability) -> KumoController {
        KumoController(
            paths: paths,
            useServiceBackend: true,
            systemProxyCommandRunner: .live,
            reachability: reachability,
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil
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
