import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show current Kumo runtime state.",
            aliases: ["st"]
        )

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let status = try CLIRuntime.current.controller.status()
            CLIRuntime.current.write(status) { status in
                let prefix = status.state == .running ? "[ok] " : ""
                return "\(prefix)\(status.state.rawValue) mode=\(status.mode.rawValue) pid=\(status.pid.map(String.init) ?? "-")"
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start Kumo with the managed Mihomo core.")

        @Option(name: .long, help: "Use a specific Mihomo core executable.")
        var core: String?
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            if core == nil {
                try await installManagedCoreIfNeeded()
            }
            let runtime = CLIRuntime.current
            let status = try runtime.controller.start(corePath: core)
            do {
                try await runtime.controller.waitForControllerReady()
            } catch {
                let pid = status.pid.map(String.init) ?? "-"
                throw KumoError.commandFailed(
                    "Mihomo core started with pid \(pid) but its controller did not become ready: \(error.localizedDescription) Check the core log at \(runtime.controller.paths.coreLogFile.path)."
                )
            }
            runtime.write(status) { "started pid=\($0.pid.map(String.init) ?? "-")" }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop Kumo.")

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let status = try CLIRuntime.current.controller.stop()
            CLIRuntime.current.write(status) { _ in "stopped" }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart Kumo.")

        @Option(name: .long, help: "Use a specific Mihomo core executable.")
        var core: String?
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            if core == nil {
                try await installManagedCoreIfNeeded()
            }
            let status = try CLIRuntime.current.controller.restart(corePath: core)
            CLIRuntime.current.write(status) { "restarted pid=\($0.pid.map(String.init) ?? "-")" }
        }
    }

    struct Mode: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set outbound mode.")

        @Argument(help: "Outbound mode: rule, global, or direct.")
        var mode: OutboundMode
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            try await CLIRuntime.current.controller.setMode(mode)
            CLIRuntime.current.write(["mode": mode.rawValue]) { _ in "mode \(mode.rawValue)" }
        }
    }

    struct Proxies: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List proxy groups and selected proxies.",
            aliases: ["proxy"]
        )

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let groups = try await CLIRuntime.current.controller.proxyGroups()
            CLIRuntime.current.write(groups) { groups in
                groups.map { "\($0.name): \($0.selectedProxyName ?? "-")" }.joined(separator: "\n")
            }
        }
    }

    struct Select: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Select a proxy for a group.")

        @Argument(help: "Proxy group name.")
        var group: String
        @Argument(help: "Proxy name.")
        var proxy: String
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            try await CLIRuntime.current.controller.selectProxy(group: group, name: proxy)
            CLIRuntime.current.write(["group": group, "proxy": proxy]) { _ in "selected \(proxy) for \(group)" }
        }
    }

    struct Providers: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show proxy and rule providers, or update them.",
            subcommands: [Overview.self, Update.self],
            defaultSubcommand: Overview.self
        )

        struct Overview: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show proxy and rule provider counts.")
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let report = ProviderReport(
                    proxies: try await CLIRuntime.current.controller.proxyProviders(),
                    rules: try await CLIRuntime.current.controller.ruleProviders()
                )
                CLIRuntime.current.write(report) { report in
                    "Proxy providers: \(report.proxies.count)\nRule providers: \(report.rules.count)"
                }
            }
        }

        struct Update: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Update a proxy provider, rule provider, or GeoIP data.")

            @Option(name: .long, help: "Proxy provider name to update.")
            var proxy: String?
            @Option(name: .long, help: "Rule provider name to update.")
            var rule: String?
            @Flag(name: .long, help: "Upgrade the GeoIP / GeoSite data files.")
            var geo = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if proxy == nil && rule == nil && !geo {
                    throw ValidationError("Provide at least one of --proxy <name>, --rule <name>, or --geo.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                var actions: [String] = []
                if let proxy {
                    try await controller.updateProxyProvider(name: proxy)
                    actions.append("updated proxy provider \(proxy)")
                }
                if let rule {
                    try await controller.updateRuleProvider(name: rule)
                    actions.append("updated rule provider \(rule)")
                }
                if geo {
                    try await controller.upgradeGeoData()
                    actions.append("requested GeoIP data upgrade")
                }
                let report = ProvidersUpdateReport(proxyProvider: proxy, ruleProvider: rule, geoData: geo)
                CLIRuntime.current.write(report) { _ in actions.joined(separator: "\n") }
            }
        }
    }

    struct Rules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List Mihomo rules or toggle one by index.",
            subcommands: [List.self, Enable.self, Disable.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List Mihomo rules with enabled state.")
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let rules = try await CLIRuntime.current.controller.rules()
                CLIRuntime.current.write(rules) { rules in
                    rules.map { rule in
                        "[\(rule.isEnabled ? "on" : "off")] \(rule.index) \(rule.type) \(rule.payload) -> \(rule.proxy)"
                    }.joined(separator: "\n")
                }
            }
        }

        struct Enable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Enable a rule by index.")
            @Argument(help: "Rule index shown by `kumo rules`.")
            var index: Int
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                try await CLIRuntime.current.controller.setRuleEnabled(index: index, isEnabled: true)
                CLIRuntime.current.write(RuleTogglePayload(index: index, isEnabled: true)) { "rule \($0.index) enabled" }
            }
        }

        struct Disable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable a rule by index.")
            @Argument(help: "Rule index shown by `kumo rules`.")
            var index: Int
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                try await CLIRuntime.current.controller.setRuleEnabled(index: index, isEnabled: false)
                CLIRuntime.current.write(RuleTogglePayload(index: index, isEnabled: false)) { "rule \($0.index) disabled" }
            }
        }
    }

    struct TestLatency: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test",
            abstract: "Test proxy or group latency."
        )

        @Argument(help: "Proxy or group name.")
        var target: String
        @Option(name: .long, help: "Test URL for a single proxy.")
        var url: String?
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            guard let url else { return }
            guard let parsed = URL(string: url), parsed.scheme != nil else {
                throw ValidationError("Invalid test URL: \(url)")
            }
        }

        mutating func run() async throws {
            try options.install()
            let controller = CLIRuntime.current.controller
            let groups = try await controller.proxyGroups()
            if let group = groups.first(where: { $0.name == target }) {
                let nodes = try await controller.testGroupDelay(group: group)
                CLIRuntime.current.write(nodes) { nodes in
                    nodes.map { "\($0.name): \($0.delay.map { "\($0)ms" } ?? "timeout")" }.joined(separator: "\n")
                }
                return
            }

            let delay = try await controller.testProxyDelay(proxy: target, testURL: url)
            let report = ProxyDelayReport(proxy: target, url: url, delay: delay)
            CLIRuntime.current.write(report) { report in
                "\(report.proxy): \(report.delay.map { "\($0)ms" } ?? "timeout")"
            }
        }
    }

    struct RuntimeEvents: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "runtime-events",
            abstract: "Show recent Kumo runtime events."
        )

        @Option(name: .long, help: "Maximum number of events.")
        var limit: Int = 100
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let events = try CLIRuntime.current.controller.runtimeEvents(limit: limit)
            CLIRuntime.current.write(events) { events in
                events.map { "\($0.time): \($0.kind) \($0.message)" }.joined(separator: "\n")
            }
        }
    }

    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inspect runtime, profile, and core candidates.")

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let runtime = CLIRuntime.current
            let report = try runtime.measure("doctor") {
                try DoctorReport(
                    status: runtime.measure("status") { try runtime.controller.status() },
                    currentProfile: runtime.measure("profile") { try runtime.controller.currentProfile() },
                    coreCandidates: runtime.measure("core-candidates") { try runtime.controller.coreCandidates() }
                )
            }
            runtime.write(report) { report in
                "State: \(report.status.state.rawValue)\nProfile: \(report.currentProfile.name)\nCore candidates: \(report.coreCandidates.count)"
            }
        }
    }
}
