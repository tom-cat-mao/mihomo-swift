import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class AgentProtocolTests: XCTestCase {
    func testCapabilitiesCoversEveryRunnableCommandExactlyOnce() {
        let entries = AgentCommandCatalog.entries
        let paths = entries.map(\.commandPath)

        XCTAssertEqual(Set(paths).count, paths.count, "CommandIndex produced duplicate runnable paths")
        XCTAssertEqual(
            AgentCommandCatalog.descriptorPaths,
            Set(paths),
            "Every runnable command needs exactly one capabilities descriptor; non-runnable groups must not be described"
        )

        let report = AgentCommandCatalog.capabilities()
        XCTAssertEqual(report.protocolVersion, "1.1")
        XCTAssertEqual(report.cliVersion, KumoCommand.configuration.version)
        XCTAssertEqual(report.commands.map(\.path), paths)
        XCTAssertEqual(report.promptPages, AgentGuidance.guides.map(\.page))
        XCTAssertFalse(report.globalParameters.isEmpty)
        for command in report.commands {
            XCTAssertFalse(command.usage.isEmpty, command.path)
            XCTAssertFalse(command.summary.isEmpty, command.path)
            XCTAssertEqual(Set(command.parameters.map(\.name)).count, command.parameters.count, command.path)
        }
    }

    func testDefaultSubcommandFormsExposeTheirDefaultUsageAndParameters() throws {
        let report = AgentCommandCatalog.capabilities()
        let commands = Dictionary(uniqueKeysWithValues: report.commands.map { ($0.path, $0) })

        let logs = try XCTUnwrap(commands["logs"])
        let runtime = try XCTUnwrap(commands["logs runtime"])
        XCTAssertEqual(logs.parameters, runtime.parameters)
        XCTAssertFalse(logs.usage.contains("<subcommand>"))
        XCTAssertTrue(logs.parameters.contains { $0.name == "--follow" })

        let prefs = try XCTUnwrap(commands["prefs"])
        let get = try XCTUnwrap(commands["prefs get"])
        XCTAssertEqual(prefs.parameters, get.parameters)
        XCTAssertFalse(prefs.usage.contains("<subcommand>"))
    }

    func testCapabilitiesSafetyClaimsAreExplicitAndCurrent() {
        let report = AgentCommandCatalog.capabilities()
        let commands = Dictionary(uniqueKeysWithValues: report.commands.map { ($0.path, $0) })

        XCTAssertEqual(Set(report.capabilities.read), Set(report.commands.filter { $0.access == .read }.map(\.path)))
        XCTAssertEqual(Set(report.capabilities.write), Set(report.commands.filter { $0.access == .write }.map(\.path)))
        XCTAssertEqual(Set(report.capabilities.protected), Set(report.commands.filter { $0.access == .protected }.map(\.path)))
        XCTAssertEqual(Set(report.capabilities.dryRun), [
            "logs clean",
            "config diff", "config validate", "config set", "profile delete", "profile update", "profile edit",
            "override add", "override delete", "prefs set", "dns set", "sniffer set",
            "sysproxy on", "sysproxy off", "sysproxy reclaim", "sysproxy set",
            "cli-link install", "cli-link uninstall", "tun settings",
            "agent install", "agent uninstall", "agent migrate",
            "skills install", "skills uninstall"
        ])
        XCTAssertEqual(Set(report.capabilities.validate), [
            "config validate", "config apply", "config set", "profile update", "profile edit", "override add", "prefs set",
            "dns set", "sniffer set", "sysproxy set", "tun settings", "agent migrate"
        ])
        XCTAssertEqual(Set(report.capabilities.rollback), ["config apply", "config rollback"])
        XCTAssertEqual(commands["config diff"]?.supportsDryRun, true)
        XCTAssertEqual(commands["config validate"]?.supportsValidate, true)
        XCTAssertEqual(commands["config apply"]?.supportsRollback, true)
        XCTAssertEqual(commands["config rollback"]?.supportsRollback, true)
        XCTAssertTrue(report.commands.filter { $0.supportsRollback }.allSatisfy {
            $0.path == "config apply" || $0.path == "config rollback"
        })

        XCTAssertEqual(commands["sysproxy on"]?.access, .protected)
        XCTAssertEqual(commands["tun enable"]?.access, .protected)
        XCTAssertEqual(commands["service install"]?.access, .protected)
        XCTAssertEqual(commands["profile delete"]?.risk, .high)
        XCTAssertEqual(commands["logs runtime"]?.outputStability, .stableStream)
        XCTAssertEqual(commands["traffic"]?.outputStability, .stableStream)
        XCTAssertEqual(commands["help"]?.outputStability, .humanText)
        XCTAssertEqual(commands["completion"]?.outputStability, .humanText)
    }

    func testDnsSourceCapabilityDescribesPositionalEnum() throws {
        let report = AgentCommandCatalog.capabilities()
        let command = try XCTUnwrap(report.commands.first { $0.path == "dns source" })
        let source = try XCTUnwrap(command.parameters.first)

        XCTAssertEqual(command.access, .write)
        XCTAssertFalse(command.supportsDryRun)
        XCTAssertEqual(command.parameters.count, 1)
        XCTAssertEqual(source.name, "source")
        XCTAssertEqual(source.kind, .argument)
        XCTAssertTrue(source.isRequired)
        XCTAssertEqual(source.acceptedValues, ["kumo", "profile"])
        XCTAssertEqual(source.summary, "DNS settings source.")
    }

    func testCapabilitiesUsesOrdinaryStableJSONEnvelope() throws {
        let response = CLIResponse(ok: true, data: AgentCommandCatalog.capabilities())
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["data"] is [String: Any])
        XCTAssertTrue(object["error"] is NSNull)
        let payload = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertEqual(payload["protocolVersion"] as? String, "1.1")
        XCTAssertNotNil(payload["commands"] as? [[String: Any]])
        XCTAssertNotNil(payload["globalParameters"] as? [[String: Any]])
    }

    func testCapabilitiesAndPromptCommandsParse() throws {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["capabilities", "--json"]))

        let command = try KumoCommand.parseAsRoot(["prompt", "topology", "route", "--json"])
        let prompt = try XCTUnwrap(command as? KumoCommand.Prompt)
        XCTAssertEqual(prompt.page, "topology")
        XCTAssertEqual(prompt.intent, "route")
        XCTAssertTrue(prompt.options.json)
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["prompt", "--list", "--json"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["prompt", "overview", "connect", "--list"]))
    }

    func testPromptPagesAndIntentIDsAreCompleteAndUnique() {
        let expected = [
            "overview", "profiles", "proxies", "topology", "connections", "logs",
            "rules", "core", "systemProxy", "dns", "tun", "sniffer", "resources",
            "overrides", "agents", "settings"
        ]
        XCTAssertEqual(AgentGuidance.guides.map(\.page), expected)
        for guide in AgentGuidance.guides {
            XCTAssertFalse(guide.intents.isEmpty, guide.page)
            XCTAssertEqual(Set(guide.intents.map(\.id)).count, guide.intents.count, guide.page)
            for intent in guide.intents {
                XCTAssertFalse(intent.goal.isEmpty, "\(guide.page).\(intent.id)")
                XCTAssertFalse(intent.steps.isEmpty, "\(guide.page).\(intent.id)")
            }
        }
    }

    func testEveryPromptStepReferencesARegisteredCommand() {
        let commandPaths = AgentCommandCatalog.entries.map(\.commandPath).sorted {
            $0.split(separator: " ").count > $1.split(separator: " ").count
        }

        for guide in AgentGuidance.guides {
            for intent in guide.intents {
                for step in intent.steps {
                    let rawTokens = step.command.split(separator: " ").map(String.init)
                    XCTAssertEqual(rawTokens.first, "kumo", step.command)
                    let tokens = rawTokens.dropFirst()
                    let match = commandPaths.first { path in
                        tokens.starts(with: path.split(separator: " ").map(String.init))
                    }
                    XCTAssertNotNil(match, "Unregistered command in \(guide.page).\(intent.id): \(step.command)")
                }
            }
        }

        let allSteps = AgentGuidance.guides.flatMap(\.intents).flatMap(\.steps).map(\.command).joined(separator: "\n")
        XCTAssertTrue(allSteps.contains("kumo topology --issues --json"))
        XCTAssertTrue(allSteps.contains("kumo config diff --file <path> --json"))
        XCTAssertTrue(allSteps.contains("kumo config validate --file <path> --json"))
        XCTAssertTrue(allSteps.contains("kumo config apply --file <path> --json"))
        XCTAssertTrue(allSteps.contains("kumo config rollback --json"))
    }

    func testPromptRenderingAndUnknownIntentErrors() throws {
        for guide in AgentGuidance.guides {
            let prompt = try AgentGuidance.prompt(page: guide.page)
            XCTAssertTrue(prompt.contains("Goal: \(guide.intents[0].goal)."), guide.page)
            XCTAssertTrue(prompt.contains("kumo capabilities --json"), guide.page)
            XCTAssertTrue(prompt.contains("1. `\(guide.intents[0].steps[0].command)`"), guide.page)

            for intent in guide.intents {
                let selected = try AgentGuidance.prompt(page: guide.page, intent: intent.id)
                XCTAssertTrue(selected.contains("Goal: \(intent.goal)."))
            }
        }

        XCTAssertThrowsError(try AgentGuidance.prompt(page: "missing")) { error in
            guard case .unknownPage(let page, let available) = error as? AgentGuidanceError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(page, "missing")
            XCTAssertEqual(available, AgentGuidance.guides.map(\.page))
        }
        XCTAssertThrowsError(try AgentGuidance.prompt(page: "overview", intent: "missing")) { error in
            guard case .unknownIntent(let page, let intent, let available) = error as? AgentGuidanceError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(page, "overview")
            XCTAssertEqual(intent, "missing")
            XCTAssertEqual(available, ["connect", "diagnose", "mode"])
        }
    }

    func testPromptPayloadKeepsStableEnvelopeAndStructuredSteps() throws {
        let guide = try XCTUnwrap(AgentGuidance.guide(for: "topology"))
        let intent = try XCTUnwrap(guide.intents.first { $0.id == "route" })
        let payload = AgentPromptPayload(
            page: guide.page,
            intent: intent.id,
            goal: intent.goal,
            steps: intent.steps,
            prompt: try AgentGuidance.prompt(page: guide.page, intent: intent.id)
        )
        let data = try JSONEncoder().encode(CLIResponse(ok: true, data: payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try XCTUnwrap(object["data"] as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertTrue(object["error"] is NSNull)
        XCTAssertEqual(body["page"] as? String, "topology")
        XCTAssertEqual(body["intent"] as? String, "route")
        XCTAssertEqual((body["steps"] as? [[String: Any]])?.count, intent.steps.count)
        XCTAssertTrue((body["prompt"] as? String)?.contains("kumo rules --json") == true)
    }
}
