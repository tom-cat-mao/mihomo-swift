import Foundation
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

@MainActor
final class KumoAppStorePhase2Tests: XCTestCase {
    func testRefreshRollbacksLoadsAndUpdatesOnExternalRollbacksNotification() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }
        try prepareFakeCore(paths: paths)

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let profileFile = paths.applicationSupportDirectory.appendingPathComponent("initial.yaml")
        try "mixed-port: 7889\nproxies: []\nproxy-groups: []\nrules: []\n".write(
            to: profileFile,
            atomically: true,
            encoding: .utf8
        )
        _ = try controller.importProfile(from: profileFile)
        _ = try await controller.applyConfiguration(profileYAML: "mixed-port: 7890\nproxies: []\n")

        let store = KumoAppStore(controller: controller)
        await store.refreshRollbacks()
        XCTAssertEqual(store.rollbackSummaries.count, 1)
        XCTAssertEqual(store.latestRollbackSummary?.id, store.rollbackSummaries.first?.id)

        store.startControlPlaneObservation(debounceInterval: 0.02)
        defer { store.stopControlPlaneObservation() }

        _ = try await controller.applyConfiguration(profileYAML: "mixed-port: 7891\nproxies: []\n")

        ControlPlaneNotifier.shared.post(
            domains: [.rollbacks],
            appSupportPath: paths.applicationSupportDirectory.standardizedFileURL.path,
            senderPID: ProcessInfo.processInfo.processIdentifier + 999
        )

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && store.externalRevision(for: .rollbacks) == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.externalRevision(for: .rollbacks), 1)
        XCTAssertEqual(store.rollbackSummaries.count, 2)
    }

    func testRollbackConfigurationRestoresPriorProfileAndClearsRollbackPoint() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }
        try prepareFakeCore(paths: paths)

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let profileFile = paths.applicationSupportDirectory.appendingPathComponent("initial.yaml")
        try "mixed-port: 7889\nproxies: []\nproxy-groups: []\nrules: []\n".write(
            to: profileFile,
            atomically: true,
            encoding: .utf8
        )
        let original = try controller.importProfile(from: profileFile)
        let originalContent = try controller.profileContent(id: original.id)

        _ = try await controller.applyConfiguration(profileYAML: "mixed-port: 7999\nproxies: []\n")
        XCTAssertNotEqual(try controller.profileContent(id: original.id), originalContent)

        let store = KumoAppStore(controller: controller)
        await store.refreshRollbacks()
        XCTAssertEqual(store.rollbackSummaries.count, 1)

        await store.rollbackConfiguration()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try controller.profileContent(id: original.id), originalContent)
        XCTAssertTrue(store.rollbackSummaries.isEmpty)
        XCTAssertNil(store.latestRollbackSummary)
    }

    func testLoadActivityLogsMergesCLIAndRuntimeEntriesDescending() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        try "2026-10-05 10:00:01 +0000 notice from-cli\n".write(
            to: paths.logsDirectory.appendingPathComponent("cli.log"),
            atomically: true,
            encoding: .utf8
        )
        let runtimeEvent = RuntimeEventEntry(
            id: "runtime-1",
            time: Date(timeIntervalSince1970: 2_000_000_000),
            kind: "config.apply",
            message: "from-runtime"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(runtimeEvent)
        var line = String(decoding: data, as: UTF8.self)
        line.append("\n")
        try line.write(to: paths.runtimeEventsFile, atomically: true, encoding: .utf8)

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        await store.loadActivityLogs()

        XCTAssertEqual(store.activityLogs.map(\.message), ["from-runtime", "from-cli"])
        XCTAssertEqual(store.activityLogs.map(\.source), [.runtime, .cli])
    }

    func testExportAndImportBackupRoundTripsAndRefreshesStore() async throws {
        let sourcePaths = hermeticPaths()
        let targetPaths = hermeticPaths()
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePaths.applicationSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetPaths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sourcePaths.applicationSupportDirectory)
            try? FileManager.default.removeItem(at: targetPaths.applicationSupportDirectory)
            try? FileManager.default.removeItem(at: backupDirectory)
        }

        let sourceController = KumoController(paths: sourcePaths, useServiceBackend: false)
        let profileFile = sourcePaths.applicationSupportDirectory.appendingPathComponent("imported.yaml")
        try "mixed-port: 7892\nproxies: []\nproxy-groups: []\nrules: []\n".write(
            to: profileFile,
            atomically: true,
            encoding: .utf8
        )
        let importedProfile = try sourceController.importProfile(from: profileFile)
        var status = try sourceController.status()
        status.mode = .global
        try CoreStateStore(paths: sourcePaths).save(status)

        let sourceStore = KumoAppStore(controller: sourceController)
        let exported = await sourceStore.exportBackup(to: backupDirectory)
        XCTAssertTrue(exported)
        XCTAssertNil(sourceStore.errorMessage)

        let targetController = KumoController(paths: targetPaths, useServiceBackend: false)
        let targetStore = KumoAppStore(controller: targetController)
        let imported = await targetStore.importBackup(from: backupDirectory)
        XCTAssertTrue(imported)
        XCTAssertNil(targetStore.errorMessage)
        XCTAssertEqual(targetStore.profiles.map(\.id), [importedProfile.id])
        XCTAssertEqual(targetStore.status.mode, .global)
    }

    func testRefreshCoreMigrationPlanPopulatesPlan() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        XCTAssertNil(store.coreMigrationPlan)

        await store.refreshCoreMigrationPlan()
        XCTAssertNotNil(store.coreMigrationPlan)
        XCTAssertEqual(store.coreMigrationPlan?.action, CoreMigrationPlan.Action.none)
    }

    private func prepareFakeCore(paths: KumoPaths) throws {
        try paths.prepare()
        let coreURL = paths.applicationSupportDirectory.appendingPathComponent("fake-mihomo")
        let script = """
        #!/bin/sh
        if [ "${1:-}" = "-t" ]; then
          exit 0
        fi
        exit 99
        """
        try script.write(to: coreURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)
        try CoreStateStore(paths: paths).save(CoreStatus(state: .stopped, corePath: coreURL.path))
    }

    private func hermeticPaths() -> KumoPaths {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return KumoPaths(
            applicationSupportDirectory: directory,
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }
}
