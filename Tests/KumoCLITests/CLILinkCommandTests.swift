import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class CLILinkCommandTests: XCTestCase {
    // MARK: - Parsing

    func testCLILinkCommandsParse() throws {
        let status = try XCTUnwrap(try KumoCommand.parseAsRoot(["cli-link", "status", "--json"]) as? KumoCommand.CLILink.Status)
        XCTAssertTrue(status.options.json)

        let install = try XCTUnwrap(try KumoCommand.parseAsRoot(["cli-link", "install", "--dry-run", "--json"]) as? KumoCommand.CLILink.Install)
        XCTAssertTrue(install.dryRun)
        XCTAssertTrue(install.options.json)

        let uninstall = try XCTUnwrap(try KumoCommand.parseAsRoot(["cli-link", "uninstall"]) as? KumoCommand.CLILink.Uninstall)
        XCTAssertFalse(uninstall.dryRun)

        // `cli-link` defaults to `status`.
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["cli-link"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["cli-link", "status"]))
    }

    // MARK: - Status payload

    func testCLILinkStatusEncodingKeepsStableKeys() throws {
        let status = CLILinkStatus(
            state: .installed,
            targetPath: "/usr/local/bin/kumo",
            bundledCLIPath: "/Applications/Kumo.app/Contents/Helpers/kumo",
            linkResolvedPath: "/Applications/Kumo.app/Contents/Helpers/kumo",
            message: "Installed at /usr/local/bin/kumo."
        )
        let data = try JSONEncoder().encode(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["state", "targetPath", "bundledCLIPath", "linkResolvedPath", "message"])
        XCTAssertEqual(object["state"] as? String, "installed")
        XCTAssertEqual(object["targetPath"] as? String, "/usr/local/bin/kumo")
    }

    func testCLILinkStatusSummaryShowsStateAndPaths() {
        let status = CLILinkStatus(
            state: .notInstalled,
            targetPath: "/usr/local/bin/kumo",
            bundledCLIPath: "/tmp/kumo",
            linkResolvedPath: nil,
            message: "Not installed."
        )

        XCTAssertEqual(
            cliLinkStatusSummary(status),
            "state=notInstalled target=/usr/local/bin/kumo bundled=/tmp/kumo link=-"
        )
        XCTAssertTrue(cliLinkStatusText(status).contains("Not installed."))
    }

    // MARK: - Dry-run report

    func testCLILinkDryRunReportNamesIntendedActionWithoutWriting() throws {
        let status = CLILinkStatus(
            state: .notInstalled,
            targetPath: "/usr/local/bin/kumo",
            bundledCLIPath: "/tmp/kumo",
            linkResolvedPath: nil,
            message: "Not installed."
        )
        let install = CLILinkActionReport(action: "install", dryRun: true, status: status)

        let data = try JSONEncoder().encode(install)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["action"] as? String, "install")
        XCTAssertEqual(object["dryRun"] as? Bool, true)
        XCTAssertNotNil(object["status"] as? [String: Any])

        let installText = cliLinkActionText(install)
        XCTAssertTrue(installText.contains("[dry-run] would install the kumo CLI link at /usr/local/bin/kumo"), installText)
        XCTAssertTrue(installText.contains("state=notInstalled"), installText)

        let uninstall = CLILinkActionReport(action: "uninstall", dryRun: true, status: status)
        XCTAssertTrue(cliLinkActionText(uninstall).contains("[dry-run] would uninstall"))
    }

    // MARK: - Help

    func testCLILinkHelpTopicsMentionAuthorizationAndDryRun() {
        let topic = HelpText.topic(["cli-link"])
        XCTAssertTrue(topic.contains("kumo cli-link install [--dry-run] [--json]"))
        XCTAssertTrue(topic.contains("administrator authorization"))
        XCTAssertTrue(HelpText.topic(["cli-link", "install"]).contains("/usr/local/bin/kumo"))
        XCTAssertTrue(CompletionScripts.commandNames.contains("cli-link"))
    }
}
