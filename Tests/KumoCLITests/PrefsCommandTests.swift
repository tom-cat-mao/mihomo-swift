import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class PrefsCommandTests: XCTestCase {
    // MARK: - Hermetic fixtures

    private func makeController() throws -> KumoController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-prefs-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return KumoController(
            paths: KumoPaths(applicationSupportDirectory: root),
            useServiceBackend: false
        )
    }

    // MARK: - Parsing

    func testPrefsCommandsParseKeysValuesAndFlags() throws {
        let whole = try XCTUnwrap(try KumoCommand.parseAsRoot(["prefs", "get"]) as? KumoCommand.Prefs.Get)
        XCTAssertNil(whole.key)

        let key = try XCTUnwrap(try KumoCommand.parseAsRoot(["prefs", "get", "updateChannel", "--json"]) as? KumoCommand.Prefs.Get)
        XCTAssertEqual(key.key, "updateChannel")
        XCTAssertTrue(key.options.json)

        let set = try XCTUnwrap(
            try KumoCommand.parseAsRoot(["prefs", "set", "keepCoreRunningOnQuit", "true", "--dry-run", "--json"]) as? KumoCommand.Prefs.Set
        )
        XCTAssertEqual(set.key, "keepCoreRunningOnQuit")
        XCTAssertEqual(set.value, "true")
        XCTAssertTrue(set.dryRun)
        XCTAssertTrue(set.options.json)

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["prefs", "set", "updateChannel", "beta"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["prefs", "set", "appLanguage", "zh-Hans"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["prefs", "set", "appLanguage", "system"]))
    }

    func testPrefsRejectsUnknownKeysAndStrictTypes() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prefs", "get", "nope"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Unknown preferences key 'nope'"), message)
            XCTAssertTrue(message.contains("launchAtLogin"), message)
        }
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prefs", "set", "nope", "true"])) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("Unknown preferences key 'nope'"))
        }
        for invalid in ["yes", "1", "TRUE"] {
            XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prefs", "set", "launchAtLogin", invalid])) { error in
                XCTAssertTrue(Self.failureMessage(error).contains("Expected true or false"), invalid)
            }
        }
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prefs", "set", "updateChannel", "nightly"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("stable, beta"), message)
        }
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prefs", "set", "appLanguage", "not a tag"])) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("BCP-47"), Self.failureMessage(error))
        }
    }

    // MARK: - Read-modify-write

    func testPrefsSetPreservesEveryOtherStoredKey() throws {
        let controller = try makeController()
        try controller.updateUserPreferences(UserPreferences(
            launchAtLogin: true,
            hideMenuBarIcon: true,
            quitOnLastWindowClose: true,
            keepCoreRunningOnQuit: true,
            updateChannel: .beta,
            updateManifestURL: URL(string: "https://example.com/manifest.json"),
            appLanguage: "zh-Hans",
            hasCompletedOnboarding: true
        ))

        let report = try applyPrefsSet(to: controller, key: "launchAtLogin", rawValue: "false", dryRun: false)

        XCTAssertFalse(report.dryRun)
        XCTAssertEqual(report.key, "launchAtLogin")
        XCTAssertEqual(report.value, "false")
        XCTAssertFalse(report.preferences.launchAtLogin)
        XCTAssertTrue(report.preferences.hideMenuBarIcon)
        XCTAssertTrue(report.preferences.keepCoreRunningOnQuit)
        XCTAssertEqual(report.preferences.updateChannel, .beta)
        XCTAssertEqual(report.preferences.appLanguage, "zh-Hans")

        let stored = controller.userPreferences()
        XCTAssertFalse(stored.launchAtLogin)
        XCTAssertTrue(stored.hideMenuBarIcon)
        XCTAssertTrue(stored.quitOnLastWindowClose)
        XCTAssertTrue(stored.keepCoreRunningOnQuit)
        XCTAssertEqual(stored.updateChannel, .beta)
        XCTAssertEqual(stored.updateManifestURL?.absoluteString, "https://example.com/manifest.json")
        XCTAssertEqual(stored.appLanguage, "zh-Hans")
        XCTAssertTrue(stored.hasCompletedOnboarding)
    }

    func testPrefsSetTypesApplyPerKey() throws {
        let controller = try makeController()

        _ = try applyPrefsSet(to: controller, key: "updateChannel", rawValue: "beta", dryRun: false)
        _ = try applyPrefsSet(to: controller, key: "appLanguage", rawValue: "zh-Hans", dryRun: false)
        _ = try applyPrefsSet(to: controller, key: "hasCompletedOnboarding", rawValue: "true", dryRun: false)

        XCTAssertEqual(controller.userPreferences().updateChannel, .beta)
        XCTAssertEqual(controller.userPreferences().appLanguage, "zh-Hans")
        XCTAssertTrue(controller.userPreferences().hasCompletedOnboarding)

        _ = try applyPrefsSet(to: controller, key: "appLanguage", rawValue: "system", dryRun: false)
        XCTAssertNil(controller.userPreferences().appLanguage)
    }

    func testPrefsSetDryRunDoesNotWrite() throws {
        let controller = try makeController()
        try controller.updateUserPreferences(UserPreferences(appLanguage: "en"))

        let report = try applyPrefsSet(to: controller, key: "appLanguage", rawValue: "system", dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.value, "system")
        XCTAssertNil(report.preferences.appLanguage)
        XCTAssertEqual(controller.userPreferences().appLanguage, "en")
    }

    func testPrefsSetReportsLifecycleNotes() throws {
        let controller = try makeController()

        let launch = try applyPrefsSet(to: controller, key: "launchAtLogin", rawValue: "true", dryRun: true)
        XCTAssertTrue(launch.notes.contains { $0.contains("next GUI launch") }, "\(launch.notes)")
        let keep = try applyPrefsSet(to: controller, key: "keepCoreRunningOnQuit", rawValue: "true", dryRun: true)
        XCTAssertTrue(keep.notes.contains { $0.contains("next GUI quit") }, "\(keep.notes)")
        let hidden = try applyPrefsSet(to: controller, key: "hideMenuBarIcon", rawValue: "true", dryRun: true)
        XCTAssertTrue(hidden.notes.contains { $0.contains("GUI-only") }, "\(hidden.notes)")
        let onboarding = try applyPrefsSet(to: controller, key: "hasCompletedOnboarding", rawValue: "false", dryRun: true)
        XCTAssertTrue(onboarding.notes.contains { $0.contains("recovery") }, "\(onboarding.notes)")
        let channel = try applyPrefsSet(to: controller, key: "updateChannel", rawValue: "stable", dryRun: true)
        XCTAssertTrue(channel.notes.isEmpty)
    }

    // MARK: - Payload shapes

    func testPrefsSnapshotEncodesStableKeysWithNullLanguage() throws {
        let data = try JSONEncoder().encode(PrefsSnapshot(UserPreferences()))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), [
            "launchAtLogin", "hideMenuBarIcon", "quitOnLastWindowClose", "keepCoreRunningOnQuit",
            "updateChannel", "appLanguage", "hasCompletedOnboarding"
        ])
        XCTAssertEqual(object["launchAtLogin"] as? Bool, false)
        XCTAssertEqual(object["updateChannel"] as? String, "stable")
        XCTAssertTrue(object["appLanguage"] is NSNull)
    }

    func testPrefsSetReportEncodesMergedPreferences() throws {
        let controller = try makeController()
        let report = try applyPrefsSet(to: controller, key: "appLanguage", rawValue: "pt-BR", dryRun: true)

        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["key"] as? String, "appLanguage")
        XCTAssertEqual(object["value"] as? String, "pt-BR")
        XCTAssertEqual(object["dryRun"] as? Bool, true)
        XCTAssertEqual(object["notes"] as? [String], [])
        let preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertEqual(preferences["appLanguage"] as? String, "pt-BR")
    }

    // MARK: - Text output and help

    func testPrefsTextOutputMarksDryRunAndNotes() throws {
        let controller = try makeController()
        let report = try applyPrefsSet(to: controller, key: "keepCoreRunningOnQuit", rawValue: "true", dryRun: true)
        let text = prefsSetText(report)

        XCTAssertTrue(text.hasPrefix("[dry-run] would set keepCoreRunningOnQuit=true"), text)
        XCTAssertTrue(text.contains("keepCoreRunningOnQuit=true"), text)
        XCTAssertTrue(text.contains("note: takes effect on the next GUI quit"), text)
        XCTAssertTrue(prefsSnapshotSummary(report.preferences).contains("updateChannel=stable"))
    }

    func testPrefsHelpTopicsCoverGetAndSet() {
        XCTAssertTrue(HelpText.topic(["prefs"]).contains("kumo prefs set <key> <value>"))
        XCTAssertTrue(HelpText.topic(["prefs"]).contains("stable|beta"))
        XCTAssertTrue(HelpText.topic(["prefs", "get"]).contains("launchAtLogin"))
        XCTAssertTrue(HelpText.topic(["prefs", "set"]).contains("--dry-run"))
        XCTAssertTrue(CompletionScripts.commandNames.contains("prefs"))
    }

    // MARK: - Helpers

    private static func failureMessage(_ error: Error) -> String {
        [(error as? LocalizedError)?.errorDescription, String(describing: error)]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
