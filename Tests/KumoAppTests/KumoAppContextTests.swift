import Foundation
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

@MainActor
final class KumoAppContextTests: XCTestCase {
    func testAttachIsIdempotentAndNeverClobbersTheLiveStore() {
        let context = KumoAppContext()
        let first = makeStore()
        let second = makeStore()

        context.attach(store: first)
        XCTAssertTrue(context.store === first)

        context.attach(store: first)
        XCTAssertTrue(context.store === first, "re-attaching the same store must be a no-op")

        context.attach(store: second)
        XCTAssertTrue(context.store === first, "a second attach must not replace the live store")
    }

    /// Cold-launch regression guard: with no view ever appearing, an intent
    /// must resolve the startup-attached store instead of failing with
    /// "Kumo is launching". `KumoApp.init` performs the same attach during
    /// launch.
    func testSetModeIntentResolvesStoreWithoutAnyView() async throws {
        let paths = hermeticPaths()
        let store = makeStore(paths: paths)
        KumoAppContext.shared.attach(store: store)

        let intent = SetKumoModeIntent()
        intent.mode = .global
        _ = try await intent.perform()

        XCTAssertTrue(KumoAppContext.shared.store === store)
        XCTAssertEqual(store.status.mode, .global)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try CoreStateStore(paths: paths).load().mode, .global)
    }

    // MARK: - Helpers

    private func makeStore(paths: KumoPaths? = nil) -> KumoAppStore {
        KumoAppStore(controller: KumoController(paths: paths ?? hermeticPaths(), useServiceBackend: false))
    }

    private func hermeticPaths() -> KumoPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return KumoPaths(
            applicationSupportDirectory: directory,
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }
}
