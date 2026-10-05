import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoServiceManagerTests: XCTestCase {
    func testHelperCandidatesFindBundledHelperForCLIInHelpersDirectory() throws {
        let bundleURL = URL(fileURLWithPath: "/Applications/Kumo.app/Contents/Helpers", isDirectory: true)
        let workingDirectory = URL(fileURLWithPath: "/Users/test/projects", isDirectory: true)

        let candidates = KumoServiceManager.helperExecutableCandidates(
            bundleURL: bundleURL,
            executableURL: bundleURL.appendingPathComponent("kumo"),
            workingDirectory: workingDirectory,
            installedHelperURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/Kumo/KumoService")
        )

        let bundledHelper = URL(fileURLWithPath: "/Applications/Kumo.app/Contents/MacOS/KumoService")
        XCTAssertTrue(candidates.contains { $0.path == bundledHelper.path })

        let bundledIndex = try XCTUnwrap(candidates.firstIndex { $0.path == bundledHelper.path })
        let workingDirectoryIndex = try XCTUnwrap(
            candidates.firstIndex { $0.path == workingDirectory.appendingPathComponent("KumoService").path }
        )
        XCTAssertLessThan(bundledIndex, workingDirectoryIndex)
    }

    func testHelperCandidatesPreferAppBundleHelperForGUIResolution() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Kumo.app", isDirectory: true)

        let candidates = KumoServiceManager.helperExecutableCandidates(
            bundleURL: bundleURL,
            executableURL: bundleURL.appendingPathComponent("Contents/MacOS/KumoApp"),
            workingDirectory: URL(fileURLWithPath: "/Users/test/projects", isDirectory: true),
            installedHelperURL: URL(fileURLWithPath: "/Users/test/Library/Application Support/Kumo/KumoService")
        )

        XCTAssertEqual(candidates.first?.path, "/Applications/Kumo.app/Contents/MacOS/KumoService")
    }

    // MARK: - Shared credentials retention

    func testUninstallKeepsSharedCredentialsWhileUserAgentIsInstalled() throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        try FileManager.default.createDirectory(
            at: paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: paths.userAgentPlistFile)

        let recorder = ServiceCommandRecorder()
        let manager = KumoServiceManager(paths: paths, serviceCommandRunner: recorder.runner())
        _ = try manager.uninstallService()

        XCTAssertEqual(recorder.invocations(), [[
            "service",
            "uninstall",
            "--app-support",
            paths.applicationSupportDirectory.path,
        ]])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.serviceCredentialsFile.path),
            "kumod still needs the shared credentials to start"
        )
    }

    func testUninstallDeletesSharedCredentialsWhenUserAgentIsAbsent() throws {
        let paths = hermeticPaths()
        _ = try KumoServiceManager(paths: paths).ensureCredentials()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.serviceCredentialsFile.path))

        let manager = KumoServiceManager(paths: paths, serviceCommandRunner: { _, _ in })
        _ = try manager.uninstallService()

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serviceCredentialsFile.path))
    }

    private func hermeticPaths() -> KumoPaths {
        KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            launchAgentsDirectory: temporaryDirectory(),
            environment: [:]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// Records privileged service-command invocations so uninstall bookkeeping can
/// be asserted without osascript authorization.
private final class ServiceCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func runner() -> @Sendable ([String], String) throws -> Void {
        { [self] arguments, _ in
            lock.lock()
            recorded.append(arguments)
            lock.unlock()
        }
    }

    func invocations() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
