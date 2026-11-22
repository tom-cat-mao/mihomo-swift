import Foundation
import XCTest
@testable import KumoCoreKit

final class SystemProxyOwnershipTests: XCTestCase {
    func testOwnershipDetectsEndpointPACAndBypassConflicts() {
        let applied = SystemProxyApplied(
            networkService: "Wi-Fi",
            mode: .manual,
            host: "127.0.0.1",
            port: 7890,
            bypassList: ["localhost"]
        )
        let owned = manualSnapshot(host: "localhost", port: 7890, bypass: ["localhost"])
        XCTAssertEqual(applied.ownership(of: owned), .owned)
        XCTAssertEqual(applied.ownership(of: manualSnapshot(host: "127.0.0.1", port: 7890, bypass: ["other"])), .takenOver)

        var withPAC = owned
        withPAC.autoProxy = autoProxyOutput(enabled: true, url: "http://other/proxy.pac")
        XCTAssertEqual(applied.ownership(of: withPAC), .takenOver)
        XCTAssertEqual(applied.ownership(of: clearedSnapshot()), .cleared)

        let pac = SystemProxyApplied(
            networkService: "Wi-Fi",
            mode: .pac,
            host: "127.0.0.1",
            port: 7890,
            pacURL: "http://127.0.0.1:5000/proxy.pac"
        )
        var pacSnapshot = clearedSnapshot()
        pacSnapshot.autoProxy = autoProxyOutput(enabled: true, url: pac.pacURL!)
        XCTAssertEqual(pac.ownership(of: pacSnapshot), .owned)
        pacSnapshot.autoProxy = autoProxyOutput(enabled: true, url: "http://other/proxy.pac")
        XCTAssertEqual(pac.ownership(of: pacSnapshot), .takenOver)
    }

    func testStatusObservesAppliedServiceAfterStoredServiceChanges() throws {
        let paths = temporaryPaths()
        let applied = manualApplied()
        try CoreStateStore(paths: paths).save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(networkService: "Ethernet"),
            systemProxyApplied: applied
        ))
        let fake = FakeSystemProxyCommandRunner(snapshots: [
            "Wi-Fi": manualSnapshot(),
            "Ethernet": manualSnapshot(host: "10.0.0.2", port: 7897)
        ])
        let controller = SystemProxyController(paths: paths, commandRunner: fake.makeRunner())

        let status = try controller.reconcileOwnership()

        XCTAssertEqual(status.systemProxyOwnership, .owned)
        XCTAssertEqual(status.systemProxySettings?.networkService, "Ethernet")
        XCTAssertEqual(Set(fake.capturedServices()), ["Wi-Fi"])
    }

    func testApplyingANewServiceReleasesOnlyTheOldOwnedService() async throws {
        let paths = temporaryPaths()
        try CoreStateStore(paths: paths).save(CoreStatus(
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(),
            systemProxyApplied: manualApplied()
        ))
        let fake = FakeSystemProxyCommandRunner(snapshots: [
            "Wi-Fi": manualSnapshot(),
            "Ethernet": clearedSnapshot(networkService: "Ethernet")
        ])
        let controller = SystemProxyController(
            paths: paths,
            commandRunner: fake.makeRunner(),
            targetPortProbe: { _, _ in true }
        )

        _ = try await controller.setEnabled(
            true,
            configuration: SystemProxyConfiguration(networkService: "Ethernet", port: 7890)
        )

        XCTAssertTrue(fake.snapshot("Wi-Fi").isCleared)
        XCTAssertEqual(fake.snapshot("Ethernet").web.port, 7890)
        XCTAssertEqual(fake.snapshot("Ethernet").web.host, "127.0.0.1")
        XCTAssertEqual(try CoreStateStore(paths: paths).load().systemProxyApplied?.networkService, "Ethernet")
    }

    func testForeignTakeoverIsReportedAndDisableDoesNotClearIt() throws {
        let paths = temporaryPaths()
        let previous = manualSnapshot(host: "192.168.1.2", port: 8080)
        try CoreStateStore(paths: paths).save(CoreStatus(
            systemProxyEnabled: true,
            previousSystemProxySnapshot: previous,
            systemProxyApplied: manualApplied(),
            systemProxyOwnership: .owned
        ))
        let foreign = manualSnapshot(host: "127.0.0.1", port: 7897)
        let fake = FakeSystemProxyCommandRunner(snapshots: ["Wi-Fi": foreign])
        let controller = SystemProxyController(paths: paths, commandRunner: fake.makeRunner())

        XCTAssertEqual(try controller.reconcileOwnership().systemProxyOwnership, .takenOver)
        let commands = try controller.disableSynchronously()

        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(fake.snapshot("Wi-Fi"), foreign)
        let stored = try CoreStateStore(paths: paths).load()
        XCTAssertFalse(stored.systemProxyEnabled)
        XCTAssertNil(stored.systemProxyApplied)
        var storedPrevious = stored.previousSystemProxySnapshot
        storedPrevious?.capturedAt = previous.capturedAt
        XCTAssertEqual(storedPrevious, previous)
    }

    func testExternalClearTurnsIntentOffAndAutoReclaimDoesNotFight() async throws {
        let paths = temporaryPaths()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(),
            systemProxyApplied: manualApplied(),
            systemProxyOwnership: .owned
        ))
        try UserPreferencesStore(paths: paths).save(UserPreferences(reclaimSystemProxy: true))
        let fake = FakeSystemProxyCommandRunner(snapshots: ["Wi-Fi": clearedSnapshot()])
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: fake.makeRunner(),
            systemProxyTargetPortProbe: { _, _ in true }
        )

        let first = try await controller.systemProxyStatus()
        let second = try await controller.systemProxyStatus()

        XCTAssertEqual(first.ownership, .cleared)
        XCTAssertFalse(first.enabled)
        XCTAssertFalse(first.active)
        XCTAssertEqual(second.ownership, .cleared)
        XCTAssertTrue(fake.runArguments().isEmpty)
    }

    func testManualReclaimAppliesKumoAndKeepsForeignSnapshot() async throws {
        let paths = temporaryPaths()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(),
            systemProxyApplied: manualApplied(),
            systemProxyOwnership: .owned
        ))
        let foreign = manualSnapshot(host: "127.0.0.1", port: 7897)
        let fake = FakeSystemProxyCommandRunner(snapshots: ["Wi-Fi": foreign])
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: fake.makeRunner(),
            systemProxyTargetPortProbe: { _, _ in true }
        )

        let before = try await controller.systemProxyStatus()
        XCTAssertEqual(before.ownership, .takenOver)
        XCTAssertTrue(fake.runArguments().isEmpty)

        let reclaimed = try await controller.reclaimSystemProxy()

        XCTAssertEqual(reclaimed.ownership, .owned)
        XCTAssertTrue(reclaimed.active)
        XCTAssertEqual(fake.snapshot("Wi-Fi").web.port, 7890)
        var previous = try CoreStateStore(paths: paths).load().previousSystemProxySnapshot
        previous?.capturedAt = foreign.capturedAt
        XCTAssertEqual(previous, foreign)
    }

    func testAutomaticReclaimIsOptIn() async throws {
        let paths = temporaryPaths()
        try CoreStateStore(paths: paths).save(CoreStatus(
            state: .running,
            systemProxyEnabled: true,
            systemProxySettings: SystemProxySettings(),
            systemProxyApplied: manualApplied(),
            systemProxyOwnership: .owned
        ))
        try UserPreferencesStore(paths: paths).save(UserPreferences(reclaimSystemProxy: true))
        let fake = FakeSystemProxyCommandRunner(snapshots: [
            "Wi-Fi": manualSnapshot(host: "127.0.0.1", port: 7897)
        ])
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: fake.makeRunner(),
            systemProxyTargetPortProbe: { _, _ in true }
        )

        let status = try await controller.systemProxyStatus()

        XCTAssertEqual(status.ownership, .owned)
        XCTAssertFalse(fake.runArguments().isEmpty)
        XCTAssertEqual(fake.snapshot("Wi-Fi").web.port, 7890)
    }

    func testStopAndGuardianPreserveIntentWithoutClearingForeignValues() throws {
        for guardian in [false, true] {
            let paths = temporaryPaths()
            try CoreStateStore(paths: paths).save(CoreStatus(
                systemProxyEnabled: true,
                systemProxySettings: SystemProxySettings(),
                systemProxyApplied: manualApplied()
            ))
            let foreign = manualSnapshot(host: "127.0.0.1", port: 7897)
            let fake = FakeSystemProxyCommandRunner(snapshots: ["Wi-Fi": foreign])
            let controller = KumoController(
                paths: paths,
                useServiceBackend: false,
                systemProxyCommandRunner: fake.makeRunner()
            )

            if guardian {
                try controller.releaseSystemProxyForGuardian()
            } else {
                _ = try controller.stop()
            }

            let stored = try CoreStateStore(paths: paths).load()
            XCTAssertTrue(stored.systemProxyEnabled)
            XCTAssertNil(stored.systemProxyApplied)
            XCTAssertEqual(fake.snapshot("Wi-Fi"), foreign)
            XCTAssertTrue(fake.runArguments().isEmpty)
        }
    }

    func testIncrementalStateAndPreferencesDecodeLegacyJSON() throws {
        let legacyState = """
        {
          "state": "stopped",
          "mode": "rule",
          "endpoint": { "host": "127.0.0.1", "port": 9097, "secret": "" },
          "proxyPorts": { "mixedPort": 7890 },
          "systemProxyEnabled": false
        }
        """
        let status = try JSONDecoder().decode(CoreStatus.self, from: Data(legacyState.utf8))
        XCTAssertNil(status.systemProxyApplied)
        XCTAssertNil(status.systemProxyOwnership)

        let preferences = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        XCTAssertFalse(preferences.reclaimSystemProxy)

        let snapshot = try JSONDecoder().decode(
            SystemProxySnapshot.self,
            from: try JSONEncoder().encode(SystemProxySnapshot(networkService: "Wi-Fi"))
        )
        XCTAssertNil(snapshot.autoProxy)
        XCTAssertTrue(snapshot.isCleared)
    }

    // MARK: - Fixtures

    private func temporaryPaths() -> KumoPaths {
        KumoPaths(applicationSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }
}

func manualApplied(
    networkService: String = "Wi-Fi",
    host: String = "127.0.0.1",
    port: Int = 7890
) -> SystemProxyApplied {
    SystemProxyApplied(
        networkService: networkService,
        mode: .manual,
        host: host,
        port: port,
        bypassList: SystemProxySettings.defaultBypassList
    )
}

func manualSnapshot(
    networkService: String = "Wi-Fi",
    host: String = "127.0.0.1",
    port: Int = 7890,
    bypass: [String] = SystemProxySettings.defaultBypassList
) -> SystemProxySnapshot {
    SystemProxySnapshot(
        networkService: networkService,
        webProxy: proxyOutput(enabled: true, host: host, port: port),
        secureWebProxy: proxyOutput(enabled: true, host: host, port: port),
        socksProxy: proxyOutput(enabled: true, host: host, port: port),
        bypassDomains: bypass.joined(separator: "\n"),
        autoProxy: autoProxyOutput(enabled: false, url: "")
    )
}

func clearedSnapshot(networkService: String = "Wi-Fi") -> SystemProxySnapshot {
    SystemProxySnapshot(
        networkService: networkService,
        webProxy: proxyOutput(enabled: false, host: "", port: 0),
        secureWebProxy: proxyOutput(enabled: false, host: "", port: 0),
        socksProxy: proxyOutput(enabled: false, host: "", port: 0),
        bypassDomains: "",
        autoProxy: autoProxyOutput(enabled: false, url: "")
    )
}

func proxyOutput(enabled: Bool, host: String, port: Int) -> String {
    "Enabled: \(enabled ? "Yes" : "No")\nServer: \(host)\nPort: \(port)"
}

func autoProxyOutput(enabled: Bool, url: String) -> String {
    "URL: \(url)\nEnabled: \(enabled ? "Yes" : "No")"
}

/// In-memory networksetup double. Every mutation updates only a per-test
/// snapshot; no process, socket, or real macOS proxy setting is touched.
final class FakeSystemProxyCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: SystemProxySnapshot]
    private var commands: [ShellCommand] = []
    private var captures: [ShellCommand] = []
    private var runError: Error?

    init(snapshots: [String: SystemProxySnapshot]) {
        self.snapshots = snapshots
    }

    func failRuns(with error: Error) {
        lock.lock()
        runError = error
        lock.unlock()
    }

    func makeRunner() -> SystemProxyCommandRunner {
        SystemProxyCommandRunner(
            run: { command in
                self.lock.lock()
                self.commands.append(command)
                let error = self.runError
                if error == nil { self.apply(command) }
                self.lock.unlock()
                if let error { throw error }
            },
            captureOutput: { command in
                self.lock.lock()
                defer { self.lock.unlock() }
                self.captures.append(command)
                return self.output(for: command)
            }
        )
    }

    func snapshot(_ service: String) -> SystemProxySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[service] ?? clearedSnapshot(networkService: service)
    }

    func runArguments() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands.map(\.arguments)
    }

    func capturedServices() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return captures.compactMap { command in
            guard command.arguments.first?.hasPrefix("-get") == true, command.arguments.count > 1 else { return nil }
            return command.arguments[1]
        }
    }

    private func output(for command: ShellCommand) -> String {
        let service = command.arguments.count > 1 ? command.arguments[1] : "Wi-Fi"
        let snapshot = snapshots[service] ?? clearedSnapshot(networkService: service)
        switch command.arguments.first {
        case "-getwebproxy": return snapshot.webProxy
        case "-getsecurewebproxy": return snapshot.secureWebProxy
        case "-getsocksfirewallproxy": return snapshot.socksProxy
        case "-getproxybypassdomains": return snapshot.bypassDomains
        case "-getautoproxyurl": return snapshot.autoProxy ?? autoProxyOutput(enabled: false, url: "")
        default: return ""
        }
    }

    private func apply(_ command: ShellCommand) {
        let arguments = command.arguments
        guard let operation = arguments.first, arguments.count >= 2 else { return }
        let service = arguments[1]
        var snapshot = snapshots[service] ?? clearedSnapshot(networkService: service)
        switch operation {
        case "-setwebproxy":
            snapshot.webProxy = proxyOutput(enabled: true, host: arguments[2], port: Int(arguments[3]) ?? 0)
        case "-setsecurewebproxy":
            snapshot.secureWebProxy = proxyOutput(enabled: true, host: arguments[2], port: Int(arguments[3]) ?? 0)
        case "-setsocksfirewallproxy":
            snapshot.socksProxy = proxyOutput(enabled: true, host: arguments[2], port: Int(arguments[3]) ?? 0)
        case "-setwebproxystate":
            snapshot.webProxy = proxyOutput(enabled: arguments[2] == "on", host: snapshot.web.host, port: snapshot.web.port)
        case "-setsecurewebproxystate":
            snapshot.secureWebProxy = proxyOutput(enabled: arguments[2] == "on", host: snapshot.secureWeb.host, port: snapshot.secureWeb.port)
        case "-setsocksfirewallproxystate":
            snapshot.socksProxy = proxyOutput(enabled: arguments[2] == "on", host: snapshot.socks.host, port: snapshot.socks.port)
        case "-setproxybypassdomains":
            snapshot.bypassDomains = arguments.dropFirst(2).joined(separator: "\n")
        case "-setautoproxyurl":
            snapshot.autoProxy = autoProxyOutput(enabled: snapshot.autoProxyEnabled, url: arguments[2])
        case "-setautoproxystate":
            snapshot.autoProxy = autoProxyOutput(enabled: arguments[2] == "on", url: snapshot.pacURL)
        default:
            break
        }
        snapshots[service] = snapshot
    }
}
