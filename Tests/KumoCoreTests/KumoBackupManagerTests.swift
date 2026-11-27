import XCTest
@testable import KumoCoreKit

final class KumoBackupManagerTests: XCTestCase {
    func testExportAndImportBackupRoundTripsProfilesAndResetsRuntimeState() throws {
        let sourcePaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let profileRepository = ProfileRepository(paths: sourcePaths)
        let stateStore = CoreStateStore(paths: sourcePaths)
        _ = try profileRepository.saveProfile(
            Profile(name: "Backup", source: .inline, rawYAML: "proxies: []"),
            preferredID: "backup"
        )
        let runtimeSettings = CoreRuntimeSettings(
            mixedPort: 7891,
            allowLAN: true,
            logLevel: "debug",
            ipv6: true
        )
        let systemProxySettings = SystemProxySettings(
            networkService: "Ethernet",
            host: "127.0.0.2",
            port: 7892,
            mode: .pac,
            bypassList: ["example.com"],
            pacScript: "function FindProxyForURL(url, host) { return DIRECT; }"
        )
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 42,
            ownerTier: .userAgent,
            mode: .global,
            proxyPorts: ProxyPortConfiguration(mixedPort: 7891),
            systemProxyEnabled: true,
            runtimeSettings: runtimeSettings,
            systemProxySettings: systemProxySettings,
            previousSystemProxySnapshot: SystemProxySnapshot(networkService: "Ethernet"),
            serviceModeStatus: ServiceModeStatus(isInstalled: true, isRunning: true),
            tunStatus: TunStatus(isEnabled: true, isRunning: true, requiresService: false),
            readiness: .providersReady,
            message: "running",
            processStartTime: 1_234,
            lastExit: CoreExit(pid: 41, exitCode: 1, expected: false, message: "previous exit")
        ))

        let backupDirectory = temporaryDirectory()
        let exported = try KumoBackupManager(paths: sourcePaths).exportBackup(to: backupDirectory)

        let destinationPaths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let manifest = try KumoBackupManager(paths: destinationPaths).importBackup(from: URL(fileURLWithPath: exported.destinationPath))

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(try ProfileRepository(paths: destinationPaths).currentProfileSummary().id, "backup")

        // A restored pid can collide with an unrelated process and a restored
        // proxy-on flag would manage this machine's network on a later start;
        // import must force those back to a stopped, proxy-off state while
        // preserving user configuration.
        let restored = try CoreStateStore(paths: destinationPaths).load()
        XCTAssertEqual(restored.state, .stopped)
        XCTAssertNil(restored.pid)
        XCTAssertNil(restored.ownerTier)
        XCTAssertNil(restored.processStartTime)
        XCTAssertNil(restored.lastExit)
        XCTAssertNil(restored.readiness)
        XCTAssertFalse(restored.systemProxyEnabled)
        XCTAssertNil(restored.previousSystemProxySnapshot)
        XCTAssertNil(restored.systemProxyApplied)
        XCTAssertNil(restored.systemProxyOwnership)
        XCTAssertNil(restored.serviceModeStatus)
        XCTAssertNil(restored.tunStatus)
        XCTAssertNil(restored.message)
        XCTAssertEqual(restored.mode, .global)
        XCTAssertEqual(restored.proxyPorts.mixedPort, 7891)
        XCTAssertEqual(restored.runtimeSettings, runtimeSettings)
        XCTAssertEqual(restored.systemProxySettings, systemProxySettings)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
