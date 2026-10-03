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

    // MARK: - Generated LaunchAgent plist

    func testLaunchAgentPlistRunsUserModeServiceOnDemand() throws {
        let paths = hermeticPaths()
        let executable = URL(fileURLWithPath: "/Applications/Kumo.app/Contents/MacOS/KumoService")
        let plist = KumoUserAgentManager.launchAgentPlist(executable: executable, paths: paths)
        let object = try plistObject(plist)

        XCTAssertEqual(object["Label"] as? String, KumoPaths.userAgentLabel)
        XCTAssertEqual(object["ProgramArguments"] as? [String], [
            executable.path,
            "service",
            "run",
            "--mode",
            "user",
            "--app-support",
            paths.applicationSupportDirectory.path,
            "--idle-timeout",
            "300"
        ])
        // On-demand: launchd holds the endpoint through `Sockets` and starts
        // the process on the first connection, so the agent is never loaded
        // at login and never kept alive.
        XCTAssertEqual(object["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(object["KeepAlive"] as? Bool, false)
        XCTAssertEqual(object["StandardOutPath"] as? String, paths.userAgentLogFile.path)
        XCTAssertEqual(object["StandardErrorPath"] as? String, paths.userAgentLogFile.path)
        XCTAssertFalse(plist.contains("--authorized-uid"))

        let sockets = try XCTUnwrap(object["Sockets"] as? [String: Any])
        let listener = try XCTUnwrap(
            sockets[KumoUserAgentManager.launchdListenerSocketName] as? [String: Any]
        )
        XCTAssertEqual(listener["SockPathName"] as? String, paths.userAgentSocketFile.path)
        XCTAssertEqual(listener["SockPathMode"] as? Int, 384)
        XCTAssertEqual(KumoUserAgentManager.launchdSocketMode, 384)
    }

    func testLaunchAgentPlistPassesConfiguredIdleTimeout() throws {
        let paths = hermeticPaths()
        let executable = URL(fileURLWithPath: "/tmp/KumoService")
        let manager = KumoUserAgentManager(paths: paths, idleTimeoutSeconds: 42)
        XCTAssertEqual(manager.idleTimeoutSeconds, 42)

        let object = try plistObject(
            KumoUserAgentManager.launchAgentPlist(
                executable: executable,
                paths: paths,
                idleTimeoutSeconds: manager.idleTimeoutSeconds
            )
        )
        let arguments = try XCTUnwrap(object["ProgramArguments"] as? [String])
        XCTAssertEqual(Array(arguments.suffix(2)), ["--idle-timeout", "42"])
    }

    func testRootLaunchDaemonPlistIsUnchangedByOnDemandWork() throws {
        let paths = KumoPaths(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/kumo-root-plist-test", isDirectory: true)
        )
        let plist = ServiceMode.rootLaunchDaemonPlist(paths: paths, authorizedUID: 501)
        let object = try plistObject(plist)

        let expected: [AnyHashable: Any] = [
            "Label": KumoServiceManager.launchDaemonLabel,
            "ProgramArguments": [
                "/Library/PrivilegedHelperTools/io.kumo.KumoService",
                "service",
                "run",
                "--app-support",
                "/tmp/kumo-root-plist-test",
                "--authorized-uid",
                "501"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": "/tmp/kumo-root-plist-test/logs/kumo-service.log",
            "StandardErrorPath": "/tmp/kumo-root-plist-test/logs/kumo-service.log"
        ]
        XCTAssertTrue(NSDictionary(dictionary: object).isEqual(to: expected))
        XCTAssertFalse(plist.contains("Sockets"))
        XCTAssertFalse(plist.contains("--mode"))
    }

    // MARK: - Idle-exit policy

    func testIdlePolicyExitsOnlyAfterTimeoutWithNoCoreAndNoRequest() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let policy = ServiceIdlePolicy(timeout: 300, now: start)

        XCTAssertFalse(policy.shouldExit(now: start.addingTimeInterval(299), isCoreRunning: false))
        XCTAssertTrue(policy.shouldExit(now: start.addingTimeInterval(300), isCoreRunning: false))
        XCTAssertTrue(policy.shouldExit(now: start.addingTimeInterval(301), isCoreRunning: false))
    }

    func testIdlePolicyNeverExitsWhileCoreIsRunning() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let policy = ServiceIdlePolicy(timeout: 5, now: start)

        XCTAssertFalse(policy.shouldExit(now: start.addingTimeInterval(10_000), isCoreRunning: true))
        XCTAssertTrue(policy.shouldExit(now: start.addingTimeInterval(10_000), isCoreRunning: false))
    }

    func testIdlePolicyNeverExitsWithRequestInFlight() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var policy = ServiceIdlePolicy(timeout: 5, now: start)
        policy.requestStarted(at: start)

        XCTAssertFalse(policy.shouldExit(now: start.addingTimeInterval(60), isCoreRunning: false))

        policy.requestFinished(at: start.addingTimeInterval(60))
        XCTAssertFalse(policy.shouldExit(now: start.addingTimeInterval(64), isCoreRunning: false))
        XCTAssertTrue(policy.shouldExit(now: start.addingTimeInterval(65), isCoreRunning: false))
    }

    func testIdlePolicyRequestActivityResetsDeadline() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var policy = ServiceIdlePolicy(timeout: 300, now: start)
        policy.requestStarted(at: start.addingTimeInterval(200))
        policy.requestFinished(at: start.addingTimeInterval(200))

        XCTAssertFalse(policy.shouldExit(now: start.addingTimeInterval(499), isCoreRunning: false))
        XCTAssertTrue(policy.shouldExit(now: start.addingTimeInterval(500), isCoreRunning: false))
    }

    func testIdlePolicyCheckIntervalIsCappedAndCorePinned() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let policy = ServiceIdlePolicy(timeout: 300, now: start)

        XCTAssertEqual(
            policy.nextCheckIntervalSeconds(at: start, isCoreRunning: false),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            policy.nextCheckIntervalSeconds(at: start.addingTimeInterval(299.95), isCoreRunning: false),
            0.1,
            accuracy: 0.001
        )
        // With a core running an exit is impossible, so the loop waits the
        // full tick instead of spinning at the (long-past) deadline.
        XCTAssertEqual(
            policy.nextCheckIntervalSeconds(at: start.addingTimeInterval(10_000), isCoreRunning: true),
            5,
            accuracy: 0.001
        )
    }

    func testIdleTimeoutParsingDefaultsOverridesAndRejectsInvalidValues() throws {
        XCTAssertEqual(ServiceIdlePolicy.defaultTimeoutSeconds, 300)
        XCTAssertEqual(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: []), 300)
        XCTAssertEqual(
            try ServiceIdlePolicy.parseTimeoutSeconds(
                arguments: ["--mode", "user", "--idle-timeout", "3", "--app-support", "/tmp/x"]
            ),
            3
        )

        XCTAssertThrowsError(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: ["--idle-timeout", "0"]))
        XCTAssertThrowsError(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: ["--idle-timeout", "-1"]))
        XCTAssertThrowsError(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: ["--idle-timeout", "abc"]))
        XCTAssertThrowsError(try ServiceIdlePolicy.parseTimeoutSeconds(arguments: ["--idle-timeout"]))
    }

    // MARK: - Helpers

    private func plistObject(_ plist: String) throws -> [String: Any] {
        let data = try XCTUnwrap(plist.data(using: .utf8))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
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
