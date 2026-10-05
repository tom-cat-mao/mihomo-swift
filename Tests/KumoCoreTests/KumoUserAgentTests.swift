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

    // MARK: - Bundled agent plist validation and install decision

    func testBundledLaunchAgentTemplateMatchesGeneratedPlistShape() throws {
        let appSupport = URL(fileURLWithPath: "/tmp/kumo-template-sync/app-support", isDirectory: true)
        let paths = KumoPaths(
            applicationSupportDirectory: appSupport,
            launchAgentsDirectory: URL(fileURLWithPath: "/tmp/kumo-template-sync/LaunchAgents", isDirectory: true),
            environment: [:]
        )
        let helperPath = "/Applications/Kumo.app/Contents/MacOS/KumoService"
        let templateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KumoCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Resources/KumoApp/LaunchAgents/io.kumo.KumoAgent.plist")

        let rendered = try String(contentsOf: templateURL, encoding: .utf8)
            .replacingOccurrences(of: "__KUMO_HELPER_PATH__", with: helperPath)
            .replacingOccurrences(of: "__KUMO_APP_SUPPORT_DIR__", with: appSupport.path)
            .replacingOccurrences(
                of: "__KUMO_AGENT_SOCKET_PATH__",
                with: appSupport.appendingPathComponent("kumo-agent.sock").path
            )
            .replacingOccurrences(
                of: "__KUMO_AGENT_LOG_PATH__",
                with: appSupport.appendingPathComponent("logs/agent.log").path
            )
            .replacingOccurrences(of: "__KUMO_IDLE_TIMEOUT__", with: "300")

        let generated = KumoUserAgentManager.launchAgentPlist(
            executable: URL(fileURLWithPath: helperPath),
            paths: paths
        )

        XCTAssertTrue(
            NSDictionary(dictionary: try plistObject(rendered))
                .isEqual(to: try plistObject(generated))
        )
    }

    func testBundledPlistValidationAcceptsCurrentMachinePaths() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let bundleURL = try makeBundledAgentFixture(in: root, programArguments: agentProgramArguments(
            executable: executable.path,
            appSupport: paths.applicationSupportDirectory.path
        ))

        XCTAssertTrue(
            KumoUserAgentManager.bundledPlistIsValidForCurrentMachine(bundleURL: bundleURL, paths: paths)
        )
    }

    func testBundledPlistValidationRejectsForeignAppSupportPath() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let bundleURL = try makeBundledAgentFixture(in: root, programArguments: agentProgramArguments(
            executable: executable.path,
            appSupport: "/Users/someone-else/Library/Application Support/Kumo"
        ))

        XCTAssertFalse(
            KumoUserAgentManager.bundledPlistIsValidForCurrentMachine(bundleURL: bundleURL, paths: paths)
        )
    }

    func testBundledPlistValidationRejectsMissingOrNonExecutableHelper() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)

        // Recorded helper path does not exist.
        let missingBundle = try makeBundledAgentFixture(
            in: root.appendingPathComponent("missing-bundle", isDirectory: true),
            programArguments: agentProgramArguments(
                executable: root.appendingPathComponent("missing/KumoService").path,
                appSupport: paths.applicationSupportDirectory.path
            )
        )
        XCTAssertFalse(
            KumoUserAgentManager.bundledPlistIsValidForCurrentMachine(
                bundleURL: missingBundle,
                paths: paths
            )
        )

        // Recorded helper path exists but is not executable.
        let plainHelper = root.appendingPathComponent("KumoService.plain")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: plainHelper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: plainHelper.path
        )
        let nonExecutableBundle = try makeBundledAgentFixture(
            in: root.appendingPathComponent("plain-bundle", isDirectory: true),
            programArguments: agentProgramArguments(
                executable: plainHelper.path,
                appSupport: paths.applicationSupportDirectory.path
            )
        )
        XCTAssertFalse(
            KumoUserAgentManager.bundledPlistIsValidForCurrentMachine(
                bundleURL: nonExecutableBundle,
                paths: paths
            )
        )
    }

    func testInstallFallsBackToGeneratedPlistWhenBundledPlistIsInvalid() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let bundleURL = try makeBundledAgentFixture(in: root, programArguments: agentProgramArguments(
            executable: executable.path,
            appSupport: "/Users/someone-else/Library/Application Support/Kumo"
        ))

        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: bundleURL,
            launchctlRunner: recorder.runner()
        )

        let status = try manager.install(executable: executable)

        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(recorder.invocations(), [
            ["bootout", "gui/\(getuid())/io.kumo.KumoAgent"],
            ["bootstrap", "gui/\(getuid())", paths.userAgentPlistFile.path],
        ])

        let generated = try String(contentsOf: paths.userAgentPlistFile, encoding: .utf8)
        let object = try plistObject(generated)
        XCTAssertEqual(object["ProgramArguments"] as? [String], [
            executable.path,
            "service",
            "run",
            "--mode",
            "user",
            "--app-support",
            paths.applicationSupportDirectory.path,
            "--idle-timeout",
            "300",
        ])
    }

    // MARK: - App-update version stamp

    func testInstallRecordsAppVersionStamp() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )

        _ = try manager.install(executable: executable, appVersion: "0.0.17")

        XCTAssertEqual(manager.recordedInstallVersion(), "0.0.17")
    }

    func testRepairReinstallsAgentWhenAppVersionChanged() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )
        _ = try manager.install(executable: executable, appVersion: "0.0.16")
        XCTAssertEqual(recorder.invocations().count, 2)

        let repaired = try manager.repairInstallIfVersionChanged(
            currentVersion: "0.0.17",
            executable: executable
        )

        XCTAssertNotNil(repaired, "a version change must re-run the idempotent install")
        XCTAssertEqual(manager.recordedInstallVersion(), "0.0.17")
        XCTAssertEqual(recorder.invocations().count, 4, "the repair must reload the LaunchAgent job")
    }

    func testRepairSkipsWhenRecordedVersionMatches() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )
        _ = try manager.install(executable: executable, appVersion: "0.0.17")

        let repaired = try manager.repairInstallIfVersionChanged(
            currentVersion: "0.0.17",
            executable: executable
        )

        XCTAssertNil(repaired)
        XCTAssertEqual(recorder.invocations().count, 2, "a current agent must not be reloaded")
    }

    func testRepairRepairsOnceWhenStampIsMissing() throws {
        // An agent installed before version stamping existed has no marker;
        // the first launch after the feature ships repairs once.
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        try FileManager.default.createDirectory(
            at: paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: paths.userAgentPlistFile)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )

        let repaired = try manager.repairInstallIfVersionChanged(
            currentVersion: "0.0.17",
            executable: executable
        )

        XCTAssertNotNil(repaired, "a missing stamp must trigger the one-time repair")
        XCTAssertEqual(manager.recordedInstallVersion(), "0.0.17")
        XCTAssertEqual(recorder.invocations().count, 2)
    }

    func testRepairSkipsWhenAgentIsNotInstalled() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )

        let repaired = try manager.repairInstallIfVersionChanged(
            currentVersion: "0.0.17",
            executable: executable
        )

        XCTAssertNil(repaired, "launch must never install an agent the user did not opt into")
        XCTAssertTrue(recorder.invocations().isEmpty)
        XCTAssertNil(manager.recordedInstallVersion())
    }

    func testUninstallRemovesAppVersionStamp() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner()
        )
        _ = try manager.install(executable: executable, appVersion: "0.0.17")

        _ = try manager.uninstall()

        XCTAssertNil(manager.recordedInstallVersion())
    }

    // MARK: - Root-owned running core install guard

    func testInstallRefusesWhenRootDaemonOwnsARunningCore() throws {
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        try CoreStateStore(paths: paths).save(CoreStatus(state: .running, pid: 4242))

        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner(),
            rootDaemonReachability: { true },
            processOwnershipProbe: { _ in .otherUser }
        )

        XCTAssertThrowsError(try manager.install(executable: executable)) { error in
            guard let kumoError = error as? KumoError,
                  case .serviceUnavailable(let message) = kumoError else {
                return XCTFail("expected serviceUnavailable, got \(error)")
            }
            XCTAssertTrue(
                message.contains("kumo agent migrate"),
                "the refusal must name the remedy: \(message)"
            )
        }

        XCTAssertTrue(recorder.invocations().isEmpty, "a refused install must not touch launchd")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.userAgentPlistFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.serviceCredentialsFile.path),
            "a refused install must not write shared credentials"
        )
    }

    func testInstallAllowsWhenRootOwnershipIsNotProvable() throws {
        let cases: [
            (
                name: String,
                status: CoreStatus,
                reachable: Bool,
                probe: KumoUserAgentManager.ProcessOwnership
            )
        ] = [
            ("no core running", CoreStatus(state: .stopped), true, .otherUser),
            ("running state without a pid", CoreStatus(state: .running, pid: nil), true, .otherUser),
            ("stale pid", CoreStatus(state: .running, pid: 4242), true, .unknown),
            ("root daemon unreachable", CoreStatus(state: .running, pid: 4242), false, .otherUser),
            ("core signalable by this process", CoreStatus(state: .running, pid: 4242), true, .sameUser),
        ]

        for testCase in cases {
            let root = temporaryDirectory()
            let paths = hermeticPaths(root: root)
            let executable = try makeExecutableFile(named: "KumoService", in: root)
            try CoreStateStore(paths: paths).save(testCase.status)

            let recorder = LaunchctlRecorder()
            let manager = KumoUserAgentManager(
                paths: paths,
                bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
                launchctlRunner: recorder.runner(),
                rootDaemonReachability: { testCase.reachable },
                processOwnershipProbe: { _ in testCase.probe }
            )

            let status = try manager.install(executable: executable)
            XCTAssertTrue(status.isInstalled, "\(testCase.name) must allow the install")
            XCTAssertEqual(recorder.invocations().count, 2, "\(testCase.name) must reload the agent")
        }
    }

    func testInstallAllowsWhenRunningCoreIsSignalableByThisProcess() throws {
        // Live `kill(pid, 0)` probe: the recorded pid is this test process, so
        // the core is locally owned, not provably root-owned.
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        ))

        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner(),
            rootDaemonReachability: { true }
        )

        let status = try manager.install(executable: executable)
        XCTAssertTrue(status.isInstalled)
    }

    func testInstallRepairsWhenAgentAlreadyInstalledAndCoreIsSignalable() throws {
        // Agent already owns a locally runnable core: reinstall/repair must
        // not be blocked by the root-owned-core guard.
        let root = temporaryDirectory()
        let paths = hermeticPaths(root: root)
        let executable = try makeExecutableFile(named: "KumoService", in: root)
        try FileManager.default.createDirectory(
            at: paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: paths.userAgentPlistFile)
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            pid: Int32(ProcessInfo.processInfo.processIdentifier)
        ))

        let recorder = LaunchctlRecorder()
        let manager = KumoUserAgentManager(
            paths: paths,
            bundleURL: root.appendingPathComponent("not-an-app", isDirectory: true),
            launchctlRunner: recorder.runner(),
            rootDaemonReachability: { true }
        )

        let status = try manager.install(executable: executable)
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(recorder.invocations().count, 2)
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
        hermeticPaths(root: temporaryDirectory())
    }

    private func hermeticPaths(root: URL) -> KumoPaths {
        KumoPaths(
            applicationSupportDirectory: root.appendingPathComponent("app-support", isDirectory: true),
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            environment: [:]
        )
    }

    private func agentProgramArguments(executable: String, appSupport: String) -> [String] {
        [
            executable,
            "service",
            "run",
            "--mode",
            "user",
            "--app-support",
            appSupport,
            "--idle-timeout",
            "300",
        ]
    }

    private func makeExecutableFile(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Builds a minimal `Kumo.app` fixture whose bundled agent plist records
    /// the supplied `ProgramArguments`, mirroring
    /// `Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist`.
    private func makeBundledAgentFixture(in root: URL, programArguments: [String]) throws -> URL {
        let bundleURL = root.appendingPathComponent("Kumo.app", isDirectory: true)
        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(KumoPaths.userAgentLabel).plist")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let object: [String: Any] = [
            "Label": KumoPaths.userAgentLabel,
            "ProgramArguments": programArguments,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL)
        return bundleURL
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// Records launchctl invocations so the install fallback can be asserted
/// without touching the real launchd domain.
private final class LaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func runner() -> @Sendable ([String]) throws -> String {
        { [self] arguments in
            lock.lock()
            recorded.append(arguments)
            lock.unlock()
            return ""
        }
    }

    func invocations() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
