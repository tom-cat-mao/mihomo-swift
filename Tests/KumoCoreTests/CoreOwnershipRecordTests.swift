import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

/// The socket tiers run their own internal `KumoController` with
/// `useServiceBackend: false`, so every local launch inside the daemon or the
/// agent routes to the local supervisor. The recorded owner must still be the
/// tier the process serves — not `localSupervisor` — or a caller reading the
/// shared state would attribute the core to the wrong tier.
final class CoreOwnershipRecordTests: XCTestCase {
    func testRootDaemonInternalControllerRecordsRootService() throws {
        try assertInternalControllerRecords(.rootService)
    }

    func testUserAgentInternalControllerRecordsUserAgent() throws {
        try assertInternalControllerRecords(.userAgent)
    }

    private func assertInternalControllerRecords(_ tier: RuntimeOwnerTier) throws {
        let paths = hermeticPaths()
        let stateStore = CoreStateStore(paths: paths)
        let corePath = try makeLongRunningCore(in: paths.applicationSupportDirectory)
        // `/core/start` enters with no explicit core path, so the controller
        // routes through the local supervisor exactly like the daemon does.
        try stateStore.save(CoreStatus(
            corePath: corePath,
            endpoint: ControllerEndpoint(port: try allocateFreeLocalPort())
        ))
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            ownerTier: tier
        )

        let running = try controller.start()

        XCTAssertEqual(running.ownerTier, tier)
        XCTAssertEqual(try stateStore.load().ownerTier, tier)

        _ = try controller.stop()
        XCTAssertNil(try stateStore.load().ownerTier)
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

    private func hermeticPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
}
