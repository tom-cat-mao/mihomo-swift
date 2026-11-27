import Foundation
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

@MainActor
final class KumoAppStoreSyncTests: XCTestCase {
    func testStoreIgnoresSelfPIDNotifications() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        store.startControlPlaneObservation(debounceInterval: 0.02)
        defer { store.stopControlPlaneObservation() }

        var prefs = controller.userPreferences()
        prefs.launchAtLogin = true
        try controller.updateUserPreferences(prefs)

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(store.externalChangeRevision, 0)
        XCTAssertEqual(store.externalRevision(for: .preferences), 0)
    }

    func testStoreIgnoresMismatchedAppSupportPath() async throws {
        let paths = hermeticPaths()
        let otherPaths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherPaths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
            try? FileManager.default.removeItem(at: otherPaths.applicationSupportDirectory)
        }

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        store.startControlPlaneObservation(debounceInterval: 0.02)
        defer { store.stopControlPlaneObservation() }

        ControlPlaneNotifier.shared.post(
            domains: [.preferences],
            appSupportPath: otherPaths.applicationSupportDirectory.standardizedFileURL.path,
            senderPID: ProcessInfo.processInfo.processIdentifier + 100
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(store.externalChangeRevision, 0)
        XCTAssertEqual(store.externalRevision(for: .preferences), 0)
    }

    func testStoreCoalescesBurstAndRefreshesTargetedDomains() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        store.startControlPlaneObservation(debounceInterval: 0.02)
        defer { store.stopControlPlaneObservation() }

        // Mutate state on disk as an external process would.
        var prefs = UserPreferences()
        prefs.hideMenuBarIcon = true
        try UserPreferencesStore(paths: paths).save(prefs)

        let overrideRepo = OverrideRepository(paths: paths)
        _ = try overrideRepo.addLocalOverride(name: "ext-override", format: .yaml, content: "rules: []\n")

        let profileRepo = ProfileRepository(paths: paths)
        let profileFile = paths.applicationSupportDirectory.appendingPathComponent("ext.yaml")
        try "mixed-port: 7890\nproxies: []\nproxy-groups: []\nrules: []\n".write(
            to: profileFile,
            atomically: true,
            encoding: .utf8
        )
        let imported = try profileRepo.importLocalProfile(from: profileFile)
        let saved = try profileRepo.saveProfile(imported)

        let foreignPID = ProcessInfo.processInfo.processIdentifier + 999
        let targetPath = paths.applicationSupportDirectory.standardizedFileURL.path

        // Post a rapid burst of separate domain notifications.
        ControlPlaneNotifier.shared.post(domains: [.preferences], appSupportPath: targetPath, senderPID: foreignPID)
        ControlPlaneNotifier.shared.post(domains: [.overrides], appSupportPath: targetPath, senderPID: foreignPID)
        ControlPlaneNotifier.shared.post(domains: [.profiles], appSupportPath: targetPath, senderPID: foreignPID)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && store.externalChangeRevision == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.externalChangeRevision, 1, "burst notifications should coalesce into one refresh batch")
        XCTAssertEqual(store.externalRevision(for: .preferences), 1)
        XCTAssertEqual(store.externalRevision(for: .overrides), 1)
        XCTAssertEqual(store.externalRevision(for: .profiles), 1)
        XCTAssertTrue(store.preferences.hideMenuBarIcon)
        XCTAssertEqual(store.overrides.map(\.name), ["ext-override"])
        XCTAssertEqual(store.profiles.map(\.id), [saved.id])
    }

    func testStoreClearsStaleLiveStateAndRefreshesSettingsOnExternalStatusStop() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let store = KumoAppStore(controller: controller)
        store.rules = [RuleEntry(id: "r1", type: "DOMAIN", payload: "example.com", proxy: "DIRECT")]
        store.connections = [ConnectionEntry(id: "c1", host: "example.com", chain: ["DIRECT"], upload: 1, download: 1, uploadSpeed: 0, downloadSpeed: 0)]
        store.proxyGroups = [ProxyGroup(name: "Proxy")]
        store.proxyProviders = [ProxyProviderEntry(name: "Sub", vehicleType: "HTTP")]
        store.ruleProviders = [RuleProviderEntry(name: "Rules", vehicleType: "HTTP")]

        store.startControlPlaneObservation(debounceInterval: 0.02)
        defer { store.stopControlPlaneObservation() }

        var stoppedStatus = CoreStatus(state: .stopped, mode: .global)
        stoppedStatus.runtimeSettings = CoreRuntimeSettings(mixedPort: 7899)
        try CoreStateStore(paths: paths).save(stoppedStatus)

        ControlPlaneNotifier.shared.post(
            domains: [.status],
            appSupportPath: paths.applicationSupportDirectory.standardizedFileURL.path,
            senderPID: ProcessInfo.processInfo.processIdentifier + 999
        )

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline && store.externalChangeRevision == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(store.externalRevision(for: .status), 1)
        XCTAssertEqual(store.status.state, .stopped)
        XCTAssertEqual(store.status.mode, .global)
        XCTAssertEqual(store.coreConfiguration.mixedPort, 7899)
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertTrue(store.proxyGroups.isEmpty)
        XCTAssertTrue(store.proxyProviders.isEmpty)
        XCTAssertTrue(store.ruleProviders.isEmpty)
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
