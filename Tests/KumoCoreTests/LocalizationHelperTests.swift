import XCTest
@testable import KumoCoreKit

final class LocalizationHelperTests: XCTestCase {
    func testAvailableLocalizationsIncludesMajorLanguages() {
        let languages = availableLocalizationsFromStringCatalog()
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("zh-Hans"))
        XCTAssertTrue(languages.contains("ja"))
        XCTAssertTrue(languages.contains("de"))
        XCTAssertGreaterThanOrEqual(languages.count, 10)
    }

    func testSettingsBackgroundKeysArePresentInCatalog() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // KumoCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/KumoCoreKit/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])

        let backgroundKeys = [
            "Background",
            "Background Agent",
            "Keep Mihomo running after quit",
            "Running",
            "Remove Background Agent?",
            "Quitting Kumo will stop the core unless Kumo Helper owns it.",
        ]

        for key in backgroundKeys {
            let entry = try XCTUnwrap(strings[key], "Missing catalog entry for \"\(key)\"")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let english = try XCTUnwrap(
                localizations["en"] as? [String: Any],
                "Missing English localization for \"\(key)\""
            )
            let unit = try XCTUnwrap(english["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["state"] as? String, "translated", "English state for \"\(key)\"")
            XCTAssertEqual(unit["value"] as? String, key, "English value for \"\(key)\"")
        }
    }
}
