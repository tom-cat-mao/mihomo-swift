import Foundation
import XCTest
@testable import KumoCoreKit

final class ControlPlaneNotifierTests: XCTestCase {
    func testDomainCasesAndCodableRoundTrip() throws {
        let allDomains = Set(ControlPlaneChangeDomain.allCases)
        XCTAssertEqual(allDomains, [.status, .profiles, .overrides, .preferences, .rollbacks, .all])

        let data = try JSONEncoder().encode(Array(allDomains))
        let decoded = try JSONDecoder().decode([ControlPlaneChangeDomain].self, from: data)
        XCTAssertEqual(Set(decoded), allDomains)
    }

    func testParseValidNotificationWithPropertyListSafePayload() throws {
        let userInfo: [AnyHashable: Any] = [
            "senderPID": Int32(4242),
            "domains": ["profiles", "status"],
            "appSupportPath": "/tmp/kumo-test"
        ]
        XCTAssertTrue(PropertyListSerialization.propertyList(userInfo, isValidFor: .binary))

        let notification = Notification(
            name: ControlPlaneNotifier.notificationName,
            object: nil,
            userInfo: userInfo
        )
        let parsed = ControlPlaneNotifier.parse(notification)

        XCTAssertEqual(
            parsed,
            ControlPlaneChangeNotification(
                senderPID: 4242,
                domains: [.profiles, .status],
                appSupportPath: "/tmp/kumo-test"
            )
        )
    }

    func testParseRejectsInvalidNotifications() {
        let wrongName = Notification(
            name: Notification.Name("io.kumo.other"),
            object: nil,
            userInfo: ["senderPID": Int32(1), "domains": ["status"]]
        )
        XCTAssertNil(ControlPlaneNotifier.parse(wrongName))

        let missingDomains = Notification(
            name: ControlPlaneNotifier.notificationName,
            object: nil,
            userInfo: ["senderPID": Int32(1)]
        )
        XCTAssertNil(ControlPlaneNotifier.parse(missingDomains))

        let emptyDomains = Notification(
            name: ControlPlaneNotifier.notificationName,
            object: nil,
            userInfo: ["senderPID": Int32(1), "domains": []]
        )
        XCTAssertNil(ControlPlaneNotifier.parse(emptyDomains))

        let missingPID = Notification(
            name: ControlPlaneNotifier.notificationName,
            object: nil,
            userInfo: ["domains": ["status"]]
        )
        XCTAssertNil(ControlPlaneNotifier.parse(missingPID))
    }

    func testPostAndObserveRoundTripThroughDistributedNotificationCenter() {
        let notifier = ControlPlaneNotifier()
        let expectedPath = "/tmp/kumo-roundtrip-\(UUID().uuidString)"
        let expectation = expectation(description: "Receive distributed control-plane notification")

        final class Box: @unchecked Sendable {
            var value: ControlPlaneChangeNotification?
        }
        let box = Box()

        let token = notifier.observe { event in
            guard event.appSupportPath == expectedPath else { return }
            box.value = event
            expectation.fulfill()
        }
        defer { notifier.removeObserver(token) }

        notifier.post(
            domains: [.overrides, .status],
            appSupportPath: expectedPath,
            senderPID: 9876
        )

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(
            box.value,
            ControlPlaneChangeNotification(
                senderPID: 9876,
                domains: [.overrides, .status],
                appSupportPath: expectedPath
            )
        )
    }

    func testControllerWriteEntryPointsEmitExpectedDomainsAndDryRunDoesNot() async throws {
        let paths = hermeticPaths()
        try FileManager.default.createDirectory(at: paths.applicationSupportDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        }

        let targetPath = paths.applicationSupportDirectory.standardizedFileURL.path
        let controller = KumoController(
            paths: paths,
            useServiceBackend: false,
            systemProxyCommandRunner: SystemProxyCommandRunner(run: { _ in }, captureOutput: { _ in "" })
        )

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var events: [ControlPlaneChangeNotification] = []

            func append(_ event: ControlPlaneChangeNotification) {
                lock.lock()
                events.append(event)
                lock.unlock()
            }

            func snapshot() -> [ControlPlaneChangeNotification] {
                lock.lock()
                defer { lock.unlock() }
                return events
            }
        }

        let collector = Collector()
        let notifier = ControlPlaneNotifier()
        let token = notifier.observe { event in
            guard event.appSupportPath == targetPath else { return }
            collector.append(event)
        }
        defer { notifier.removeObserver(token) }

        // Dry run must NOT emit.
        _ = try await controller.setSystemProxy(true, dryRun: true)

        // Preferences -> [.preferences]
        var prefs = controller.userPreferences()
        prefs.launchAtLogin = true
        try controller.updateUserPreferences(prefs)

        // Overrides -> [.overrides]
        let overrideItem = try controller.addLocalOverride(
            name: "test-override",
            format: .yaml,
            content: "rules: []\n"
        )

        // Profiles -> [.profiles]
        let profileFile = paths.applicationSupportDirectory.appendingPathComponent("sample.yaml")
        try "mixed-port: 7890\nproxies: []\nproxy-groups: []\nrules: []\n".write(
            to: profileFile,
            atomically: true,
            encoding: .utf8
        )
        let imported = try controller.importProfile(from: profileFile)
        try controller.setCurrentProfile(id: imported.id)

        // Status -> [.status]
        try await controller.setMode(.global)
        try controller.updateDnsSettings(DnsSettings(isEnabled: true))
        try controller.deleteOverride(id: overrideItem.id)

        // Wait briefly for DistributedNotificationCenter delivery.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if collector.snapshot().count >= 7 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let receivedDomains = collector.snapshot().map(\.domains)
        XCTAssertTrue(receivedDomains.contains([.preferences]))
        XCTAssertTrue(receivedDomains.contains([.overrides]))
        XCTAssertTrue(receivedDomains.contains([.profiles]))
        XCTAssertTrue(receivedDomains.contains([.status]))
        // Verify dryRun did not produce an extra status event beyond setMode + updateDnsSettings (2 status events).
        XCTAssertEqual(receivedDomains.filter { $0 == [.status] }.count, 2)
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
