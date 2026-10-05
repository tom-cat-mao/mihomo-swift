import Darwin
import Foundation
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

/// The update install flow and the launch after it. The install ends with
/// `.terminateNow`, which skips the normal termination cleanup, so the flow
/// itself must stop the Sub-Store sidecar; and the relaunched app must surface
/// the privileged-helper repair prompt when the installed helper belongs to an
/// older app version.
@MainActor
final class KumoAppStoreUpdateFlowTests: XCTestCase {
    func testUpdateInstallStopsSubStoreSidecar() async throws {
        let paths = hermeticPaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        try await controller.subStoreSupervisor.start(plan: SubStoreLaunchPlan(
            backendCommand: ShellCommand(executable: "/bin/sleep", arguments: ["600"])
        ))
        let runningPID = await controller.subStoreSupervisor.pid
        let sidecarPID = try XCTUnwrap(runningPID)
        XCTAssertTrue(isProcessAlive(sidecarPID), "fixture sidecar should be running")

        let store = KumoAppStore(controller: controller)
        await store.prepareForUpdateInstall()

        let sidecarIsRunning = await controller.subStoreSupervisor.isRunning
        XCTAssertFalse(sidecarIsRunning, "the update install path must stop the Sub-Store sidecar")
        XCTAssertFalse(
            isProcessAlive(sidecarPID),
            "the sidecar must not survive the update relaunch"
        )
    }

    func testRefreshServiceModeStatusSurfacesHelperRepairPrompt() async throws {
        let paths = hermeticPaths()
        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        let serviceManager = KumoServiceManager(paths: paths)

        // Service mode is installed, but the helper was stamped by a version
        // that cannot match the running test bundle.
        let installed = ServiceModeStatus(
            isInstalled: true,
            isRunning: false,
            socketPath: paths.serviceSocketFile.path
        )
        try FileManager.default.createDirectory(
            at: paths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(installed).write(to: paths.serviceStatusFile, options: .atomic)
        try KumoInstallVersionStamp.write(
            version: "0.0.15-test",
            to: serviceManager.helperVersionStampFile
        )

        await store.refreshServiceModeStatus()

        XCTAssertTrue(store.serviceModeStatus.isInstalled)
        XCTAssertEqual(
            store.serviceModeStatus.message,
            "Kumo Helper may be out of date. Use Install / Repair Service to update it.",
            "a stale helper must surface the guided repair prompt, never elevate on launch"
        )
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
