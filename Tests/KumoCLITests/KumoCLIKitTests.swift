import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class KumoCLIKitTests: XCTestCase {
    func testCLIResponseEncodesStableEnvelopeKeysWithNulls() throws {
        let response = CLIResponse<String>(ok: false, error: "boom")
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue(object.keys.contains("data"))
        XCTAssertTrue(object.keys.contains("error"))
        XCTAssertTrue(object["data"] is NSNull)
        XCTAssertEqual(object["error"] as? String, "boom")
    }

    func testTopLevelHelpUsesNPMStylePrompts() {
        XCTAssertTrue(HelpText.topLevel.contains("kumo <command> -h"))
        XCTAssertTrue(HelpText.topLevel.contains("kumo -l"))
        XCTAssertTrue(HelpText.topLevel.contains("kumo help <term>"))
        XCTAssertTrue(HelpText.topLevel.contains("All commands:"))
    }

    func testJSONHelpDocumentsEnvelopeAndExitCodes() {
        let help = HelpText.topic(["json"])

        XCTAssertTrue(help.contains("\"ok\": true"))
        XCTAssertTrue(help.contains("\"error\": null"))
        XCTAssertTrue(help.contains("Exit code 0 means success. Exit code 1 means failure."))
    }

    func testArgumentParserAcceptsExpectedAliasesAndRejectsBadMode() throws {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["st", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["proxy", "--json"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["mode", "auto", "--json"]))
    }

    func testRendererDisablesColorForJSON() {
        let renderer = OutputRenderer(options: RuntimeOptions(arguments: ["status", "--json", "--color", "always"]))

        XCTAssertFalse(renderer.usesColor)
        XCTAssertEqual(renderer.error("[error] boom"), "[error] boom")
    }

    func testLogRedactorRemovesSecrets() {
        let input = "Authorization: Bearer abc secret=def token=ghi https://user:pass@example.com/path"
        let output = LogRedactor.redact(input)

        XCTAssertFalse(output.contains("abc"))
        XCTAssertFalse(output.contains("def"))
        XCTAssertFalse(output.contains("ghi"))
        XCTAssertFalse(output.contains("pass@example.com"))
        XCTAssertTrue(output.contains("[redacted]"))
    }

    func testDebugLogStoreCleanSupportsDryRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = KumoPaths(applicationSupportDirectory: root)
        let options = RuntimeOptions(arguments: ["--logs-max", "1"])
        let store = DebugLogStore(paths: paths, options: options)

        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: store.directory.appendingPathComponent("2026-a-kumo-debug-0.log"))
        try Data("two".utf8).write(to: store.directory.appendingPathComponent("2026-b-kumo-debug-0.log"))

        let report = try store.clean(dryRun: true)

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.matchedFiles, 2)
        XCTAssertEqual(report.wouldRemoveFiles, 1)
    }

    // MARK: - Two-tier runtime command surface

    func testNewCommandsParseWithExpectedArguments() {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["rules", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["rules", "list", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["rules", "enable", "3", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["rules", "disable", "3"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "list", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "use", "abc"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "delete", "abc", "--dry-run", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "import", "/tmp/profile.yaml", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "content", "abc", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "refresh", "https://example.com/sub.yaml"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["dns", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["dns", "enable"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["dns", "disable"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["dns", "set", "--stdin", "--dry-run", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sniffer", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sniffer", "set", "--file", "/tmp/sniffer.json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["tun", "status", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["tun", "settings", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["tun", "settings", "--stdin", "--dry-run"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "on", "--dry-run", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "off"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "set", "--bypass", "a,b", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "set", "--file", "/tmp/proxy.json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["providers", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["providers", "update", "--proxy", "Airport"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["providers", "update", "--rule", "GeoIP", "--geo"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["test", "HK-01", "--url", "https://example.com", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["test", "Proxy", "--json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["logs", "--follow", "--level", "info", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["logs", "runtime", "--limit", "5"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["traffic", "--watch", "--json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "status", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "install", "--dry-run", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "uninstall", "--dry-run"]))
    }

    func testNewCommandsRejectMissingOrConflictingArguments() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["rules", "enable"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["traffic"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["dns", "set"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["dns", "set", "--stdin", "--file", "/tmp/dns.json"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["providers", "update"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["sysproxy", "set"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["test", "x", "--url", "not a url"]))
    }

    func testRulesEnableCarriesParsedIndex() throws {
        let command = try KumoCommand.parseAsRoot(["rules", "enable", "7"])
        let enable = try XCTUnwrap(command as? KumoCommand.Rules.Enable)
        XCTAssertEqual(enable.index, 7)
    }

    func testRuleTogglePayloadEncodesIndexAndState() throws {
        let data = try JSONEncoder().encode(RuleTogglePayload(index: 3, isEnabled: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["index"] as? Int, 3)
        XCTAssertEqual(object["isEnabled"] as? Bool, false)
    }

    func testProxyDelayAndAgentReportsEncodeStableKeys() throws {
        let delay = try JSONEncoder().encode(ProxyDelayReport(proxy: "HK-01", url: nil, delay: 42))
        let delayObject = try XCTUnwrap(JSONSerialization.jsonObject(with: delay) as? [String: Any])
        XCTAssertEqual(delayObject["proxy"] as? String, "HK-01")
        XCTAssertEqual(delayObject["delay"] as? Int, 42)

        let status = ServiceModeStatus(isInstalled: true, isRunning: false, isAvailable: false, isCurrentProcessPrivileged: false, socketPath: "/tmp/a.sock", message: nil)
        let report = try JSONEncoder().encode(
            AgentActionReport(action: "install", label: "io.kumo.KumoAgent", plistPath: "/tmp/a.plist", socketPath: "/tmp/a.sock", dryRun: true, status: status)
        )
        let reportObject = try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any])
        XCTAssertEqual(reportObject["action"] as? String, "install")
        XCTAssertEqual(reportObject["dryRun"] as? Bool, true)
        XCTAssertNotNil(reportObject["status"] as? [String: Any])
    }

    func testSettingsPatchMergesPartialJSON() throws {
        let current = DnsSettings()
        let patch = Data(#"{"ipv6": true, "cacheAlgorithm": "arc"}"#.utf8)

        let merged = try applyingSettingsPatch(patch, to: current, name: "DnsSettings")

        XCTAssertTrue(merged.ipv6)
        XCTAssertEqual(merged.cacheAlgorithm, "arc")
        XCTAssertEqual(merged.enhancedMode, current.enhancedMode)
        XCTAssertEqual(merged.nameserver, current.nameserver)
        XCTAssertEqual(merged.fakeIPFilter, current.fakeIPFilter)
    }

    func testSettingsPatchRejectsInvalidJSONAndTypes() {
        let current = DnsSettings()

        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"{"ipv6": "yes"}"#.utf8), to: current, name: "DnsSettings"))
        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"[1, 2]"#.utf8), to: current, name: "DnsSettings"))
        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"not json"#.utf8), to: current, name: "DnsSettings"))
    }

    func testSettingsPatchReplacesArraysWholesale() throws {
        let patch = Data(#"{"tlsPorts": [443, 8443]}"#.utf8)

        let merged = try applyingSettingsPatch(patch, to: SnifferSettings(), name: "SnifferSettings")

        XCTAssertEqual(merged.tlsPorts, [443, 8443])
        XCTAssertEqual(merged.httpPorts, [80, 443])
        XCTAssertEqual(merged.skipDomain, SnifferSettings().skipDomain)
    }

    func testHelpTopicsAndCompletionCoverNewCommands() {
        XCTAssertTrue(HelpText.topLevel.contains("kumo rules --json"))
        XCTAssertTrue(HelpText.topLevel.contains("kumo agent status --json"))
        XCTAssertTrue(HelpText.topLevel.contains("agent, backup"))

        XCTAssertTrue(HelpText.topic(["rules"]).contains("kumo rules enable <index>"))
        XCTAssertTrue(HelpText.topic(["profile"]).contains("kumo profile delete <id> [--dry-run]"))
        XCTAssertTrue(HelpText.topic(["dns"]).contains("kumo dns set --file <path>"))
        XCTAssertTrue(HelpText.topic(["sniffer"]).contains("SnifferSettings"))
        XCTAssertTrue(HelpText.topic(["tun", "settings"]).contains("TunSettings"))
        XCTAssertTrue(HelpText.topic(["sysproxy"]).contains("kumo sysproxy set --bypass"))
        XCTAssertTrue(HelpText.topic(["providers"]).contains("kumo providers update --geo"))
        XCTAssertTrue(HelpText.topic(["test"]).contains("kumo test <proxy|group>"))
        XCTAssertTrue(HelpText.topic(["logs"]).contains("--follow"))
        XCTAssertTrue(HelpText.topic(["traffic"]).contains("--watch"))
        XCTAssertTrue(HelpText.topic(["agent"]).contains("io.kumo.KumoAgent"))

        for command in ["rules", "test", "traffic", "dns", "sniffer", "agent"] {
            XCTAssertTrue(CompletionScripts.commandNames.contains(command))
        }
    }
}
