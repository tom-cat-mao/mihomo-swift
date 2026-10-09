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
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["providers", "update", "--all", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "set", "--add-defaults", "--json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["test", "HK-01", "--url", "https://example.com", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["test", "Proxy", "--json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["logs", "--follow", "--level", "info", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["logs", "runtime", "--limit", "5"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["traffic", "--watch", "--json"]))

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "status", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "install", "--dry-run", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "uninstall", "--dry-run"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "migrate"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["agent", "migrate", "--dry-run", "--json"]))
    }

    func testAgentMigrateCarriesDryRunFlag() throws {
        let command = try KumoCommand.parseAsRoot(["agent", "migrate", "--dry-run", "--json"])
        let migrate = try XCTUnwrap(command as? KumoCommand.Agent.Migrate)
        XCTAssertTrue(migrate.dryRun)
        XCTAssertTrue(migrate.options.json)
    }

    func testMigrationPayloadsEncodeStableKeys() throws {
        let status = ServiceModeStatus(
            isInstalled: true,
            isRunning: true,
            isAvailable: true,
            isCurrentProcessPrivileged: false,
            socketPath: "/tmp/kumo-agent.sock",
            message: nil
        )
        let tier = TierInstallState(
            installState: .dual,
            coreOwner: .rootService,
            tunEnabled: false,
            rootService: status,
            userAgent: status
        )
        let plan = CoreMigrationPlan(
            action: .handoff,
            tier: tier,
            coreRunning: true,
            blockers: [],
            reason: nil
        )

        let planData = try JSONEncoder().encode(plan)
        let planObject = try XCTUnwrap(JSONSerialization.jsonObject(with: planData) as? [String: Any])
        XCTAssertEqual(planObject["action"] as? String, "handoff")
        XCTAssertEqual(planObject["coreRunning"] as? Bool, true)
        let tierObject = try XCTUnwrap(planObject["tier"] as? [String: Any])
        XCTAssertEqual(tierObject["installState"] as? String, "dual")
        XCTAssertEqual(tierObject["coreOwner"] as? String, "rootService")
        XCTAssertNotNil(tierObject["rootService"] as? [String: Any])
        XCTAssertNotNil(tierObject["userAgent"] as? [String: Any])

        let result = CoreMigrationResult(migrated: true, plan: plan, coreState: .running, corePID: 4242)
        let resultData = try JSONEncoder().encode(result)
        let resultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        XCTAssertEqual(resultObject["migrated"] as? Bool, true)
        XCTAssertEqual(resultObject["coreState"] as? String, "running")
        XCTAssertEqual(resultObject["corePID"] as? Int, 4242)
        XCTAssertNotNil(resultObject["plan"] as? [String: Any])
    }

    func testNewCommandsRejectMissingOrConflictingArguments() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["rules", "enable"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["traffic"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["dns", "set"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["dns", "set", "--stdin", "--file", "/tmp/dns.json"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["providers", "update"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["providers", "update", "--all", "--proxy", "Airport"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["providers", "update", "--all", "--rule", "GeoIP"]))
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
        XCTAssertTrue(HelpText.topic(["agent"]).contains("kumo agent migrate [--dry-run] [--json]"))
        XCTAssertTrue(HelpText.long.contains("kumo agent migrate [--dry-run] [--json]"))

        for command in ["rules", "test", "traffic", "dns", "sniffer", "agent"] {
            XCTAssertTrue(CompletionScripts.commandNames.contains(command))
        }
    }

    // MARK: - Providers update --all and sysproxy defaults

    func testProvidersUpdateAllCollectsPartialFailures() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? { "boom" }
        }

        let report = try await KumoCommand.Providers.Update.updateAll(
            listProxyProviders: {
                [
                    ProxyProviderEntry(name: "Alpha", vehicleType: "HTTP"),
                    ProxyProviderEntry(name: "Broken", vehicleType: "HTTP")
                ]
            },
            listRuleProviders: {
                [RuleProviderEntry(name: "GeoIP", vehicleType: "HTTP")]
            },
            updateProxyProvider: { name in
                if name == "Broken" {
                    throw Boom()
                }
            },
            updateRuleProvider: { _ in
                throw Boom()
            }
        )

        XCTAssertEqual(report.results.map(\.name), ["Alpha", "Broken", "GeoIP"])
        XCTAssertEqual(report.results.map(\.kind), ["proxy", "proxy", "rule"])
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.failed, 2)
        XCTAssertFalse(report.geoData)
        XCTAssertNil(report.results[0].error)
        XCTAssertEqual(report.results[1].error, "boom")
        XCTAssertEqual(report.results[2].updated, false)

        let text = KumoCommand.Providers.Update.text(for: report)
        XCTAssertTrue(text.contains("updated 1 of 3 providers"), text)
        XCTAssertTrue(text.contains("failed proxy provider Broken: boom"), text)
        XCTAssertTrue(text.contains("failed rule provider GeoIP: boom"), text)
    }

    func testSysproxyAddDefaultsUnionsAndDedupes() throws {
        let command = try XCTUnwrap(
            try KumoCommand.parseAsRoot(["sysproxy", "set", "--add-defaults", "--dry-run", "--json"]) as? KumoCommand.Sysproxy.Set
        )
        XCTAssertTrue(command.addDefaults)
        XCTAssertTrue(command.dryRun)

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["sysproxy", "set", "--bypass", "example.com", "--add-defaults"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["sysproxy", "set"]))

        let merged = mergingSystemProxyBypassDefaults(["localhost", "example.com"])
        XCTAssertEqual(Set(merged), Set(["localhost", "example.com"] + SystemProxySettings.defaultBypassList))
        XCTAssertEqual(merged, merged.sorted())
        XCTAssertEqual(merged.count, Set(merged).count)

        // Re-merging the defaults is idempotent; duplicates from the stored
        // list are dropped.
        XCTAssertEqual(
            mergingSystemProxyBypassDefaults(SystemProxySettings.defaultBypassList),
            SystemProxySettings.defaultBypassList.sorted()
        )
    }

    // MARK: - Help system completeness

    func testTopLevelHelpListsEveryTopLevelCommandIncludingSelect() {
        for entry in CommandIndex.topLevel {
            XCTAssertTrue(HelpText.topLevel.contains(entry.name), "missing command: \(entry.name)")
        }
        XCTAssertTrue(HelpText.topLevel.contains("select"))
        XCTAssertEqual(KumoCommand.configuration.version, "0.0.17")
        XCTAssertTrue(HelpText.topLevel.contains("kumo@\(KumoCommand.configuration.version)"))
    }

    func testLongHelpEnumeratesFullCommandTree() {
        for entry in CommandIndex.all {
            XCTAssertTrue(HelpText.long.contains(entry.commandPath), "missing command path: \(entry.commandPath)")
        }
        for entry in CommandIndex.topLevel where !entry.children.isEmpty {
            let subtree = entry.descendants.map(\.commandPath).sorted().joined(separator: ", ")
            XCTAssertTrue(HelpText.long.contains("Commands: " + subtree), "missing subtree for: \(entry.name)")
        }
        XCTAssertFalse(HelpText.long.contains("kumo@0.0.1\n"))
    }

    func testEveryCommandPathResolvesToADetailedHelpTopic() {
        for entry in CommandIndex.all {
            let help = HelpText.topic(entry.path)
            XCTAssertFalse(help.contains("No detailed help found"), "no topic for: \(entry.commandPath)")
        }
    }

    func testDocumentedTopicsCarrySummaryUsageAndExample() {
        let documented = [
            "status", "start", "stop", "restart", "mode", "proxies", "select",
            "rules", "profile", "override", "prefs", "dns", "sniffer", "tun", "sysproxy",
            "cli-link", "service",
            "agent", "providers", "test", "logs", "traffic", "connections",
            "backup", "core", "config", "doctor", "runtime-events", "substore",
            "skills", "completion"
        ]
        let topLevelNames = Set(CommandIndex.topLevel.map(\.name))
        for name in documented {
            XCTAssertTrue(topLevelNames.contains(name), "topic is not a command: \(name)")
            guard let topic = HelpTopics.byPath[name] else {
                XCTFail("missing curated topic for: \(name)")
                continue
            }
            XCTAssertFalse(topic.summary.isEmpty, name)
            XCTAssertFalse(topic.usage.isEmpty, name)
            XCTAssertFalse(topic.example.isEmpty, name)
            let help = HelpText.topic([name])
            XCTAssertTrue(help.contains("Usage:"), name)
            XCTAssertTrue(help.contains("Example:"), name)
        }
    }

    func testHelpTopicResolvesAliases() {
        XCTAssertTrue(HelpText.topic(["st"]).contains("kumo status"))
        XCTAssertTrue(HelpText.topic(["proxy"]).contains("kumo proxies"))
        XCTAssertTrue(HelpText.topic(["c"]).contains("kumo config"))
        XCTAssertTrue(HelpText.topic(["LOGS", "CLI"]).contains("kumo logs cli"))
    }

    func testUnknownHelpTopicPointsAtLongHelp() {
        let help = HelpText.topic(["nope"])

        XCTAssertTrue(help.contains("No detailed help found for nope."))
        XCTAssertTrue(help.contains("kumo -l"))
    }

    func testCompletionCoversEveryTopLevelCommandAndAlias() {
        let words = Set(CompletionScripts.commandNames.split(separator: " ").map(String.init))

        XCTAssertEqual(words, Set(CommandIndex.completionWords))
        for entry in CommandIndex.topLevel {
            XCTAssertTrue(words.contains(entry.name), entry.name)
            for alias in entry.aliases {
                XCTAssertTrue(words.contains(alias), alias)
            }
        }
        XCTAssertTrue(words.contains("st"))
        XCTAssertTrue(words.contains("proxy"))
        XCTAssertTrue(words.contains("c"))
    }

    // MARK: - CLI debug log entries

    func testCLILogStoreLimitCountsEntriesNotFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = KumoPaths(applicationSupportDirectory: root)
        let store = DebugLogStore(paths: paths, options: RuntimeOptions(arguments: ["--logs-max", "10"]))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)

        let older = [
            "2026-10-05 10:00:00 +0000 info first",
            "2026-10-05 10:00:01 +0000 error second",
            "2026-10-05 10:00:02 +0000 notice third"
        ].joined(separator: "\n") + "\n"
        let newer = [
            "2026-10-05 11:00:00 +0000 info fourth",
            "2026-10-05 11:00:01 +0000 error fifth"
        ].joined(separator: "\n") + "\n"
        try Data(older.utf8).write(to: store.directory.appendingPathComponent("2026-a-kumo-debug-0.log"))
        try Data(newer.utf8).write(to: store.directory.appendingPathComponent("2026-b-kumo-debug-0.log"))

        // 3 entries from 2 files: the old file-based limit would have returned 2 summaries.
        let limited = store.recentEntries(limit: 3, minimumLevel: nil)
        XCTAssertEqual(limited.map(\.summary), ["fifth", "fourth", "third"])
        XCTAssertEqual(limited.map(\.level), [.error, .info, .notice])
        XCTAssertEqual(limited.first?.createdAt, "2026-10-05 11:00:01 +0000")

        XCTAssertEqual(
            store.recentEntries(limit: 4, minimumLevel: nil).map(\.summary),
            ["fifth", "fourth", "third", "second"]
        )
        XCTAssertEqual(
            store.recentEntries(limit: 10, minimumLevel: .error).map(\.summary),
            ["fifth", "second"]
        )
        XCTAssertTrue(store.recentEntries(limit: 0, minimumLevel: nil).isEmpty)
    }
}
