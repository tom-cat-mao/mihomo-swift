import Foundation
import XCTest
@testable import KumoCoreKit

final class KumoUserAgentTests: XCTestCase {
    func testUserAgentPathsDeriveFromInjectedRoots() {
        let root = temporaryDirectory()
        let launchAgents = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: root,
            launchAgentsDirectory: launchAgents,
            environment: [:]
        )

        XCTAssertEqual(KumoPaths.userAgentLabel, "io.kumo.KumoAgent")
        XCTAssertEqual(paths.userAgentLabel, "io.kumo.KumoAgent")
        XCTAssertEqual(paths.userAgentSocketFile, root.appendingPathComponent("kumo-agent.sock"))
        XCTAssertEqual(paths.userAgentLogFile, root.appendingPathComponent("logs/agent.log"))
        XCTAssertEqual(
            paths.userAgentPlistFile,
            launchAgents.appendingPathComponent("io.kumo.KumoAgent.plist")
        )
    }

    func testExistingRootTierPathsAreUnchanged() {
        let root = temporaryDirectory()
        let paths = KumoPaths(applicationSupportDirectory: root, environment: [:])

        XCTAssertEqual(paths.serviceSocketFile, root.appendingPathComponent("kumo-service.sock"))
        XCTAssertEqual(paths.serviceLogFile, root.appendingPathComponent("logs/kumo-service.log"))
        XCTAssertEqual(paths.serviceCredentialsFile, root.appendingPathComponent("service-credentials.json"))
    }

    // MARK: - Dev-instance environment overrides

    func testDefaultsAreByteIdenticalWithoutEnvironmentOverrides() throws {
        let paths = KumoPaths(environment: [:])
        let expectedSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ).appendingPathComponent("Kumo", isDirectory: true)

        XCTAssertEqual(paths.applicationSupportDirectory, expectedSupport)
        XCTAssertEqual(paths.userAgentLabel, "io.kumo.KumoAgent")
        XCTAssertEqual(
            paths.userAgentPlistFile,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/io.kumo.KumoAgent.plist")
        )
    }

    func testEnvironmentOverridesAppSupportRootAndAgentLabel() {
        let paths = KumoPaths(environment: [
            KumoPaths.appSupportDirectoryEnvKey: "/tmp/kumo-dev-app-support",
            KumoPaths.userAgentLabelEnvKey: "io.kumo.KumoAgent.dev",
        ])

        XCTAssertEqual(paths.applicationSupportDirectory.path, "/tmp/kumo-dev-app-support")
        XCTAssertEqual(paths.userAgentLabel, "io.kumo.KumoAgent.dev")
        XCTAssertEqual(paths.userAgentSocketFile.path, "/tmp/kumo-dev-app-support/kumo-agent.sock")
        XCTAssertEqual(paths.userAgentLogFile.path, "/tmp/kumo-dev-app-support/logs/agent.log")
        XCTAssertEqual(paths.userAgentPlistFile.lastPathComponent, "io.kumo.KumoAgent.dev.plist")
    }

    func testEnvironmentOverridesExpandTildeAndIgnoreBlankValues() {
        let expanded = KumoPaths(environment: [
            KumoPaths.appSupportDirectoryEnvKey: "~/KumoDevAppSupport",
        ])
        XCTAssertEqual(
            expanded.applicationSupportDirectory.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("KumoDevAppSupport").path
        )

        let blank = KumoPaths(environment: [
            KumoPaths.appSupportDirectoryEnvKey: "   ",
            KumoPaths.userAgentLabelEnvKey: "",
        ])
        XCTAssertEqual(
            blank.applicationSupportDirectory,
            KumoPaths(environment: [:]).applicationSupportDirectory
        )
        XCTAssertEqual(blank.userAgentLabel, "io.kumo.KumoAgent")
    }

    func testExplicitAppSupportDirectoryWinsOverEnvironment() {
        let explicit = temporaryDirectory()
        let paths = KumoPaths(
            applicationSupportDirectory: explicit,
            environment: [KumoPaths.appSupportDirectoryEnvKey: "/tmp/ignored-override"]
        )

        XCTAssertEqual(paths.applicationSupportDirectory, explicit)
    }

    func testInvalidAgentLabelOverrideFallsBackToDefault() {
        for invalid in ["", "   ", "io.kumo.KumoAgent.dev/../prod", "io.kumo.KumoAgent dev", "io.kumo.KumoAgent\tdev"] {
            XCTAssertFalse(KumoPaths.isValidUserAgentLabel(invalid))
            let paths = KumoPaths(environment: [KumoPaths.userAgentLabelEnvKey: invalid])
            XCTAssertEqual(paths.userAgentLabel, "io.kumo.KumoAgent")
        }
        XCTAssertTrue(KumoPaths.isValidUserAgentLabel("io.kumo.KumoAgent.dev"))
        XCTAssertTrue(KumoPaths.isValidUserAgentLabel("kumo_agent-dev.2"))
    }

    func testUserAgentManagerUsesEffectiveLabel() {
        let paths = KumoPaths(
            applicationSupportDirectory: temporaryDirectory(),
            launchAgentsDirectory: temporaryDirectory(),
            environment: [KumoPaths.userAgentLabelEnvKey: "io.kumo.KumoAgent.dev"]
        )
        let manager = KumoUserAgentManager(paths: paths)

        XCTAssertEqual(manager.launchAgentLabel, "io.kumo.KumoAgent.dev")
        XCTAssertEqual(manager.launchAgentPlistName, "io.kumo.KumoAgent.dev.plist")
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
        XCTAssertNil(object["EnvironmentVariables"])
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

    func testLaunchAgentPlistCarriesDevLabelAndEnvironment() throws {
        let root = temporaryDirectory()
        let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let paths = KumoPaths(
            applicationSupportDirectory: appSupport,
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            environment: [KumoPaths.userAgentLabelEnvKey: "io.kumo.KumoAgent.dev"]
        )

        let plist = KumoUserAgentManager.launchAgentPlist(
            executable: URL(fileURLWithPath: "/tmp/KumoService"),
            paths: paths
        )
        let object = try plistObject(plist)

        XCTAssertEqual(object["Label"] as? String, "io.kumo.KumoAgent.dev")
        let environment = try XCTUnwrap(object["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(
            environment[KumoPaths.userAgentLabelEnvKey] as? String,
            "io.kumo.KumoAgent.dev"
        )
        XCTAssertEqual(paths.userAgentPlistFile.lastPathComponent, "io.kumo.KumoAgent.dev.plist")

        // The socket stays in the (dev) app-support tree, not next to the
        // production endpoint.
        let sockets = try XCTUnwrap(object["Sockets"] as? [String: Any])
        let listener = try XCTUnwrap(
            sockets[KumoUserAgentManager.launchdListenerSocketName] as? [String: Any]
        )
        XCTAssertEqual(
            listener["SockPathName"] as? String,
            appSupport.appendingPathComponent("kumo-agent.sock").path
        )
    }

    func testRootLaunchDaemonPlistIsUnchangedByOnDemandWork() throws {
        let paths = KumoPaths(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/kumo-root-plist-test", isDirectory: true),
            environment: [:]
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
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            environment: [:]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
