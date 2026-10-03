import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoUserAgentTests: XCTestCase {
    func testUserAgentPathsDeriveFromInjectedRoots() {
        let root = temporaryDirectory()
        let launchAgents = temporaryDirectory()
        let paths = KumoPaths(applicationSupportDirectory: root, launchAgentsDirectory: launchAgents)

        XCTAssertEqual(KumoPaths.userAgentLabel, "io.kumo.KumoAgent")
        XCTAssertEqual(paths.userAgentSocketFile, root.appendingPathComponent("kumo-agent.sock"))
        XCTAssertEqual(paths.userAgentLogFile, root.appendingPathComponent("logs/agent.log"))
        XCTAssertEqual(
            paths.userAgentPlistFile,
            launchAgents.appendingPathComponent("io.kumo.KumoAgent.plist")
        )
    }

    func testExistingRootTierPathsAreUnchanged() {
        let root = temporaryDirectory()
        let paths = KumoPaths(applicationSupportDirectory: root)

        XCTAssertEqual(paths.serviceSocketFile, root.appendingPathComponent("kumo-service.sock"))
        XCTAssertEqual(paths.serviceLogFile, root.appendingPathComponent("logs/kumo-service.log"))
        XCTAssertEqual(paths.serviceCredentialsFile, root.appendingPathComponent("service-credentials.json"))
    }

    func testServiceModeDefaultsToRoot() throws {
        XCTAssertEqual(ServiceMode.defaultMode, .root)
        XCTAssertEqual(try ServiceMode.parse(arguments: []), .root)
        XCTAssertEqual(try ServiceMode.parse(arguments: ["--app-support", "/tmp/app-support"]), .root)
    }

    func testServiceModeParsesExplicitTier() throws {
        XCTAssertEqual(
            try ServiceMode.parse(arguments: ["--mode", "user", "--app-support", "/tmp/app-support"]),
            .user
        )
        XCTAssertEqual(try ServiceMode.parse(arguments: ["--mode", "root"]), .root)
    }

    func testServiceModeRejectsUnknownValues() {
        XCTAssertThrowsError(try ServiceMode.parse(arguments: ["--mode", "daemon"])) { error in
            XCTAssertEqual(
                error as? KumoError,
                KumoError.invalidArguments("Unknown service mode: daemon. Use root or user.")
            )
        }
    }

    func testModeSelectsTierSpecificPathsAndFlags() {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())

        XCTAssertEqual(ServiceMode.root.socketFile(in: paths), paths.serviceSocketFile)
        XCTAssertEqual(ServiceMode.user.socketFile(in: paths), paths.userAgentSocketFile)
        XCTAssertEqual(ServiceMode.root.logFile(in: paths), paths.serviceLogFile)
        XCTAssertEqual(ServiceMode.user.logFile(in: paths), paths.userAgentLogFile)
        XCTAssertEqual(ServiceMode.root.launchdLabel, KumoServiceManager.launchDaemonLabel)
        XCTAssertEqual(ServiceMode.user.launchdLabel, KumoPaths.userAgentLabel)

        XCTAssertTrue(ServiceMode.root.requiresRoot)
        XCTAssertFalse(ServiceMode.user.requiresRoot)
        XCTAssertTrue(ServiceMode.root.chownsSharedFilesToAuthorizedUID)
        XCTAssertFalse(ServiceMode.user.chownsSharedFilesToAuthorizedUID)
        XCTAssertTrue(ServiceMode.root.repairsAppSupportOwnership)
        XCTAssertFalse(ServiceMode.user.repairsAppSupportOwnership)
        XCTAssertTrue(ServiceMode.root.writesSharedStatusFile)
        XCTAssertFalse(ServiceMode.user.writesSharedStatusFile)
    }

    func testUserAgentReusesRootTierCredentialsAndTargetsAgentSocket() throws {
        let paths = hermeticPaths()
        let credentials = try KumoServiceManager(paths: paths).ensureCredentials()

        let agentManager = KumoUserAgentManager(paths: paths)
        XCTAssertEqual(try agentManager.loadCredentials(), credentials)

        let client = try XCTUnwrap(agentManager.client())
        XCTAssertEqual(client.endpoint.socketPath, paths.userAgentSocketFile.path)
        XCTAssertEqual(client.signer.credentials, credentials)
    }

    func testUserAgentStatusIsUninstalledWithoutLaunchAgent() {
        let paths = hermeticPaths()
        let status = KumoUserAgentManager(paths: paths).status()

        XCTAssertFalse(status.isInstalled)
        XCTAssertFalse(status.isRunning)
        XCTAssertFalse(status.isAvailable)
        XCTAssertEqual(status.socketPath, paths.userAgentSocketFile.path)
    }

    func testLaunchAgentPlistRunsUserModeService() {
        let paths = hermeticPaths()
        let executable = URL(fileURLWithPath: "/Applications/Kumo.app/Contents/MacOS/KumoService")
        let plist = KumoUserAgentManager.launchAgentPlist(executable: executable, paths: paths)

        XCTAssertTrue(plist.contains("<string>\(KumoPaths.userAgentLabel)</string>"))
        XCTAssertTrue(plist.contains("<string>\(executable.path)</string>"))
        XCTAssertTrue(plist.contains("<string>--mode</string>"))
        XCTAssertTrue(plist.contains("<string>user</string>"))
        XCTAssertTrue(plist.contains("<string>\(paths.applicationSupportDirectory.path)</string>"))
        XCTAssertTrue(plist.contains("<string>\(paths.userAgentLogFile.path)</string>"))
        XCTAssertFalse(plist.contains("--authorized-uid"))
    }

    private func hermeticPaths() -> KumoPaths {
        let root = temporaryDirectory()
        return KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("app-support", isDirectory: true),
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
