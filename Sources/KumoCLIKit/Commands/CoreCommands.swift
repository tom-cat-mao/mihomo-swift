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
            discussion: "With --geo, the upstream hostname of each node in the current profile is sent to the public ipwho.is GeoIP service to show a country code. The lookup is opt-in; without --geo no hostname leaves the machine and the output is unchanged.",
            aliases: ["proxy"]
        )

        @Flag(name: .long, help: "Resolve and show a country code per node (sends proxy hostnames to ipwho.is).")
        var geo = false
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let controller = CLIRuntime.current.controller
            let groups = try await controller.proxyGroups()
            let resolved = try await Self.resolve(
                groups: groups,
                geo: geo,
                nodes: { try await controller.profileNodes(id: try controller.currentProfile().id) },
                lookup: { ProxyGeoLookup(cacheURL: controller.paths.proxyGeoCacheFile) }
            )
            CLIRuntime.current.write(resolved) { groups in
                geo ? Self.geoText(groups) : Self.text(groups)
            }
        }

        /// The default text shape, unchanged by the `--geo` flag.
        static func text(_ groups: [ProxyGroup]) -> String {
            groups.map { "\($0.name): \($0.selectedProxyName ?? "-")" }.joined(separator: "\n")
        }

        /// With `--geo` each group is expanded into its nodes so the resolved
        /// country code is visible in text mode; nodes with no resolved code
        /// keep the plain name.
        static func geoText(_ groups: [ProxyGroup]) -> String {
            groups.map { group in
                let header = "\(group.name): \(group.selectedProxyName ?? "-")"
                let nodes = group.proxies.map { proxy in
                    "  \(proxy.name)\(proxy.detectedCountry.map { " [\($0)]" } ?? "")"
                }
                return ([header] + nodes).joined(separator: "\n")
            }.joined(separator: "\n")
        }

        /// Gate and enrichment seam for `--geo`, mirroring the GUI batch
        /// (`KumoAppStore.scheduleCountryDetection`): proxy names map to
        /// upstream servers through the current profile's `proxies:` section,
        /// the unique hosts are resolved with bounded concurrency, and each
        /// match is stamped onto `detectedCountry`.
        ///
        /// With `geo == false` neither `nodes` nor `lookup` is touched and the
        /// groups are returned unchanged, so the default output stays
        /// byte-identical and no hostname leaves the machine.
        static func resolve(
            groups: [ProxyGroup],
            geo: Bool,
            nodes: @Sendable () async throws -> [String: ProfileNodeInfo],
            lookup: @Sendable () -> ProxyGeoLookup
        ) async throws -> [ProxyGroup] {
            guard geo else { return groups }
            let serversByName = try await nodes().mapValues(\.server)
            guard !serversByName.isEmpty else { return groups }
            let countries = await lookup().countries(for: Array(Set(serversByName.values)))
            guard !countries.isEmpty else { return groups }
            return groups.map { group in
                var group = group
                for index in group.proxies.indices {
                    guard let server = serversByName[group.proxies[index].name],
                          let code = countries[server.lowercased()] ?? countries[server]
                    else { continue }
                    group.proxies[index].detectedCountry = code
                }
                return group
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
            static let configuration = CommandConfiguration(
                abstract: "Update a proxy provider, rule provider, GeoIP data, or all providers.",
                discussion: "Use --proxy/--rule to update one provider, --geo to upgrade the GeoIP/GeoSite data files, or --all to update every proxy and rule provider. --all collects per-provider outcomes and never stops at the first failure."
            )

            @Option(name: .long, help: "Proxy provider name to update.")
            var proxy: String?
            @Option(name: .long, help: "Rule provider name to update.")
            var rule: String?
            @Flag(name: .long, help: "Update every proxy and rule provider, reporting each outcome.")
            var all = false
            @Flag(name: .long, help: "Upgrade the GeoIP / GeoSite data files.")
            var geo = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if all, proxy != nil || rule != nil {
                    throw ValidationError("Use either --all or --proxy/--rule, not both.")
                }
                if proxy == nil && rule == nil && !geo && !all {
                    throw ValidationError("Provide at least one of --proxy <name>, --rule <name>, --geo, or --all.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                if all {
                    var report = try await Self.updateAll(
                        listProxyProviders: { try await controller.proxyProviders() },
                        listRuleProviders: { try await controller.ruleProviders() },
                        updateProxyProvider: { try await controller.updateProxyProvider(name: $0) },
                        updateRuleProvider: { try await controller.updateRuleProvider(name: $0) }
                    )
                    if geo {
                        try await controller.upgradeGeoData()
                        report.geoData = true
                    }
                    CLIRuntime.current.write(report) { Self.text(for: $0) }
                    return
                }
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

            /// Updates every listed proxy and rule provider, recording each
            /// outcome. Failures are collected instead of thrown so one broken
            /// subscription cannot hide the remaining providers; only the two
            /// provider listings themselves are allowed to fail the command.
            static func updateAll(
                listProxyProviders: () async throws -> [ProxyProviderEntry],
                listRuleProviders: () async throws -> [RuleProviderEntry],
                updateProxyProvider: (String) async throws -> Void,
                updateRuleProvider: (String) async throws -> Void
            ) async throws -> ProvidersUpdateAllReport {
                var results: [ProviderUpdateResult] = []
                for provider in try await listProxyProviders() {
                    results.append(await outcome(kind: "proxy", name: provider.name) {
                        try await updateProxyProvider(provider.name)
                    })
                }
                for provider in try await listRuleProviders() {
                    results.append(await outcome(kind: "rule", name: provider.name) {
                        try await updateRuleProvider(provider.name)
                    })
                }
                return ProvidersUpdateAllReport(
                    results: results,
                    updated: results.filter(\.updated).count,
                    failed: results.filter { !$0.updated }.count,
                    geoData: false
                )
            }

            static func text(for report: ProvidersUpdateAllReport) -> String {
                var lines = ["updated \(report.updated) of \(report.results.count) providers"]
                if report.geoData {
                    lines.append("requested GeoIP data upgrade")
                }
                for result in report.results where !result.updated {
                    lines.append("failed \(result.kind) provider \(result.name): \(result.error ?? "unknown error")")
                }
                return lines.joined(separator: "\n")
            }

            private static func outcome(
                kind: String,
                name: String,
                update: () async throws -> Void
            ) async -> ProviderUpdateResult {
                do {
                    try await update()
                    return ProviderUpdateResult(kind: kind, name: name, updated: true, error: nil)
                } catch {
                    return ProviderUpdateResult(
                        kind: kind,
                        name: name,
                        updated: false,
                        error: providerUpdateErrorMessage(error)
                    )
                }
            }

            private static func providerUpdateErrorMessage(_ error: Error) -> String {
                if let localized = error as? LocalizedError, let description = localized.errorDescription {
                    return description
                }
                return String(describing: error)
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
