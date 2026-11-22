import Foundation
import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class ConfigurationTransactionCommandTests: XCTestCase {
    func testCommandsParseOptionalAndRequiredCandidateInputs() throws {
        let diff = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "diff", "--json"]) as? KumoCommand.Config.Diff)
        XCTAssertNil(diff.file)
        XCTAssertFalse(diff.stdin)
        XCTAssertTrue(diff.options.json)

        let validate = try XCTUnwrap(try KumoCommand.parseAsRoot([
            "config", "validate", "--file", "/tmp/candidate.yaml"
        ]) as? KumoCommand.Config.Validate)
        XCTAssertEqual(validate.file, "/tmp/candidate.yaml")

        let apply = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "apply", "--stdin"]) as? KumoCommand.Config.Apply)
        XCTAssertTrue(apply.stdin)
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["config", "rollback", "--json"]))

        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "apply"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "diff", "--stdin", "--file", "/tmp/a.yaml"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "validate", "--stdin", "--file", "/tmp/a.yaml"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "apply", "--stdin", "--file", "/tmp/a.yaml"]))
    }

    func testTransactionJSONSchemasAndEnvelopeAreStable() throws {
        try assertKeys(
            CLIResponse(ok: true, data: ConfigurationDiffReport(changed: true, diff: "@@ -1 +1 @@")),
            dataKeys: ["changed", "diff"]
        )
        try assertKeys(
            CLIResponse(ok: true, data: ConfigurationValidationReport(valid: false, diagnostics: ["fatal: bad"])),
            dataKeys: ["valid", "diagnostics"]
        )
        try assertKeys(
            CLIResponse(ok: true, data: ConfigurationApplyReport(rollbackPointID: "point", snapshotCount: 2, reloaded: true)),
            dataKeys: ["rollbackPointID", "snapshotCount", "reloaded"]
        )
        try assertKeys(
            CLIResponse(ok: true, data: ConfigurationRollbackReport(rollbackPointID: "point", remainingSnapshots: 1, reloaded: true)),
            dataKeys: ["rollbackPointID", "remainingSnapshots", "reloaded"]
        )
    }

    func testHelpCoversTheWholeTransactionLoop() {
        let help = HelpText.topic(["config"])
        for command in ["diff", "validate", "apply", "rollback"] {
            XCTAssertTrue(help.contains("kumo config \(command)"), command)
            XCTAssertTrue(HelpText.topic(["config", command]).contains("kumo config \(command)"), command)
        }
        XCTAssertTrue(HelpText.topic(["config", "diff"]).contains("without writing"))
        XCTAssertTrue(HelpText.topic(["config", "apply"]).contains("rollback"))
    }

    private func assertKeys<T: Encodable>(_ response: CLIResponse<T>, dataKeys: Set<String>) throws {
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["ok", "data", "error"])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["error"] is NSNull)
        let payload = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), dataKeys)
    }
}
