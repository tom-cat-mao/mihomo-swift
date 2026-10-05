import Darwin
import Foundation
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

/// The quit path must stop the Sub-Store Node sidecar. The sidecar is a child
/// of the GUI process, so leaving it behind orphans a process that keeps
/// writing the Sub-Store data store next to the instance the relaunched app
/// spawns on a fresh port.
@MainActor
final class KumoAppStoreTerminationTests: XCTestCase {
    func testPrepareForTerminationStopsSubStoreSidecar() async throws {
        let paths = hermeticPaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        try await controller.subStoreSupervisor.start(plan: SubStoreLaunchPlan(
            backendCommand: ShellCommand(executable: "/bin/sleep", arguments: ["600"])
        ))
        let runningPID = await controller.subStoreSupervisor.pid
        let sidecarPID = try XCTUnwrap(runningPID)
        XCTAssertTrue(isProcessAlive(sidecarPID), "fixture sidecar should be running")

        let store = KumoAppStore(controller: controller)
        await store.prepareForTermination()

        let sidecarIsRunning = await controller.subStoreSupervisor.isRunning
        XCTAssertFalse(sidecarIsRunning, "app termination must stop the Sub-Store sidecar")
        XCTAssertFalse(isProcessAlive(sidecarPID), "the sidecar process must not be orphaned")
    }

    // MARK: - Helpers

    private func hermeticPaths() -> KumoPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return KumoPaths(
            applicationSupportDirectory: directory,
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0
    }
}
