import ArgumentParser
import KumoCoreKit

extension KumoCommand {
    struct Dns: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or update DNS runtime settings.",
            subcommands: [Show.self, Enable.self, Disable.self, Set.self],
            defaultSubcommand: Show.self
        )

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show DNS runtime settings.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                CLIRuntime.current.write(try CLIRuntime.current.controller.dnsSettings()) { dnsSettingsSummary($0) }
            }
        }

        struct Enable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Enable DNS.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let settings = try await CLIRuntime.current.controller.setDnsEnabled(true)
                CLIRuntime.current.write(settings) { _ in "dns enabled" }
            }
        }

        struct Disable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable DNS.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let settings = try await CLIRuntime.current.controller.setDnsEnabled(false)
                CLIRuntime.current.write(settings) { _ in "dns disabled" }
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Update DNS settings from a JSON patch.",
                discussion: "Reads a JSON object whose keys match DnsSettings; only the provided keys are changed. The core restarts when settings are applied while running."
            )

            @Option(name: .long, help: "Read a JSON settings patch from a file.")
            var file: String?
            @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Preview the update without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                try validateSettingsInput(file: file, stdin: stdin)
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let current = try controller.dnsSettings()
                let patch = try readSettingsPatchJSON(file: file, stdin: stdin)
                let settings = try applyingSettingsPatch(patch, to: current, name: "DnsSettings")
                if dryRun {
                    CLIRuntime.current.write(settings) { "[dry-run] \(dnsSettingsSummary($0))" }
                    return
                }
                let applied = try await controller.applyDnsSettings(settings)
                CLIRuntime.current.write(applied) { dnsSettingsSummary($0) }
            }
        }
    }

    struct Sniffer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or update sniffer runtime settings.",
            subcommands: [Show.self, Enable.self, Disable.self, Set.self],
            defaultSubcommand: Show.self
        )

        struct Show: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show sniffer runtime settings.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                CLIRuntime.current.write(try CLIRuntime.current.controller.snifferSettings()) { snifferSettingsSummary($0) }
            }
        }

        struct Enable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Enable the sniffer.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let settings = try await CLIRuntime.current.controller.setSnifferEnabled(true)
                CLIRuntime.current.write(settings) { _ in "sniffer enabled" }
            }
        }

        struct Disable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable the sniffer.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let settings = try await CLIRuntime.current.controller.setSnifferEnabled(false)
                CLIRuntime.current.write(settings) { _ in "sniffer disabled" }
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Update sniffer settings from a JSON patch.",
                discussion: "Reads a JSON object whose keys match SnifferSettings; only the provided keys are changed. The core restarts when settings are applied while running."
            )

            @Option(name: .long, help: "Read a JSON settings patch from a file.")
            var file: String?
            @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Preview the update without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                try validateSettingsInput(file: file, stdin: stdin)
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let current = try controller.snifferSettings()
                let patch = try readSettingsPatchJSON(file: file, stdin: stdin)
                let settings = try applyingSettingsPatch(patch, to: current, name: "SnifferSettings")
                if dryRun {
                    CLIRuntime.current.write(settings) { "[dry-run] \(snifferSettingsSummary($0))" }
                    return
                }
                let applied = try await controller.applySnifferSettings(settings)
                CLIRuntime.current.write(applied) { snifferSettingsSummary($0) }
            }
        }
    }
}

private func dnsSettingsSummary(_ settings: DnsSettings) -> String {
    [
        "enabled=\(settings.isEnabled)",
        "enhancedMode=\(settings.enhancedMode)",
        "listen=\(settings.listen.isEmpty ? "-" : settings.listen)",
        "nameserver=\(settings.nameserver.joined(separator: ","))"
    ].joined(separator: " ")
}

private func snifferSettingsSummary(_ settings: SnifferSettings) -> String {
    [
        "enabled=\(settings.isEnabled)",
        "parsePureIP=\(settings.parsePureIP)",
        "forceDNSMapping=\(settings.forceDNSMapping)",
        "httpPorts=\(settings.httpPorts.map(String.init).joined(separator: ","))",
        "tlsPorts=\(settings.tlsPorts.map(String.init).joined(separator: ","))"
    ].joined(separator: " ")
}
