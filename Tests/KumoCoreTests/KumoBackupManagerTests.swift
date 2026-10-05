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
        try stateStore.save(CoreStatus(
            state: .running,
            pid: 42,
            mode: .global,
            proxyPorts: ProxyPortConfiguration(mixedPort: 7891),
            systemProxyEnabled: true,
            readiness: .providersReady,
            message: "running"
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
        XCTAssertNil(restored.readiness)
        XCTAssertFalse(restored.systemProxyEnabled)
        XCTAssertEqual(restored.mode, .global)
        XCTAssertEqual(restored.proxyPorts.mixedPort, 7891)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
