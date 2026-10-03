import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show Kumo configuration paths.",
            subcommands: [Path.self, List.self],
            defaultSubcommand: Path.self,
            aliases: ["c"]
        )

        struct Path: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the application support path.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let paths = CLIPaths(paths: CLIRuntime.current.controller.paths)
                CLIRuntime.current.write(paths) { $0.applicationSupportDirectory }
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List Kumo CLI-visible paths.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let paths = CLIPaths(paths: CLIRuntime.current.controller.paths)
                CLIRuntime.current.write(paths) { paths in
                    [
                        "applicationSupportDirectory=\(paths.applicationSupportDirectory)",
                        "profilesDirectory=\(paths.profilesDirectory)",
                        "workDirectory=\(paths.workDirectory)",
                        "logsDirectory=\(paths.logsDirectory)",
                        "runtimeConfigFile=\(paths.runtimeConfigFile)",
                        "stateFile=\(paths.stateFile)"
                    ].joined(separator: "\n")
                }
            }
        }
    }

    struct Backup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export or import Kumo backup data.",
            subcommands: [Export.self, Import.self]
        )

        struct Export: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Export a Kumo backup.")
            @Argument(help: "Destination directory.")
            var path: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let result = try CLIRuntime.current.controller.exportBackup(to: URL(fileURLWithPath: path))
                CLIRuntime.current.write(result) { "exported backup to \($0.destinationPath)" }
            }
        }

        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Import a Kumo backup.")
            @Argument(help: "Source backup directory.")
            var path: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let manifest = try CLIRuntime.current.controller.importBackup(from: URL(fileURLWithPath: path))
                CLIRuntime.current.write(manifest) { "imported backup from \($0.createdAt)" }
            }
        }
    }

    struct Core: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the managed Mihomo core.",
            subcommands: [Install.self]
        )

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install the managed Mihomo core.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let result = try await CLIRuntime.current.controller.installManagedCore()
                CLIRuntime.current.write(result) { "installed \($0.version) at \($0.path)" }
            }
        }
    }

    struct Profile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage profiles.",
            subcommands: [List.self, Use.self, Delete.self, Import.self, Content.self, Refresh.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List profiles and the current selection.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let profiles = try CLIRuntime.current.controller.profiles()
                CLIRuntime.current.write(profiles) { profiles in
                    profiles.map { profile in
                        profile.isCurrent ? "[current] \(profile.id) \(profile.name)" : "\(profile.id) \(profile.name)"
                    }.joined(separator: "\n")
                }
            }
        }

        struct Use: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Set the current profile.")
            @Argument(help: "Profile id shown by `kumo profile list`.")
            var id: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                guard try controller.profiles().contains(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }
                try controller.setCurrentProfile(id: id)
                CLIRuntime.current.write(["id": id]) { _ in "current profile \(id)" }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Delete a profile.")
            @Argument(help: "Profile id shown by `kumo profile list`.")
            var id: String
            @Flag(name: .long, help: "Preview the deletion without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                guard id != "default" else {
                    throw ValidationError("The default profile cannot be deleted.")
                }
                guard let match = try controller.profiles().first(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }
                if dryRun {
                    let report = ProfileDeleteReport(id: id, dryRun: true, wasCurrent: match.isCurrent)
                    CLIRuntime.current.write(report) { "[dry-run] would delete \($0.id)" }
                    return
                }
                let wasCurrent = try controller.deleteProfile(id: id)
                let report = ProfileDeleteReport(id: id, dryRun: false, wasCurrent: wasCurrent)
                CLIRuntime.current.write(report) { "deleted \($0.id)" }
            }
        }

        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Import a local profile YAML file.")
            @Argument(help: "Local profile file path or file URL.")
            var url: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let fileURL = try profileFileURL(from: url)
                let profile = try CLIRuntime.current.controller.importProfile(from: fileURL)
                CLIRuntime.current.write(profile) { "imported \($0.name) (\($0.id))" }
            }
        }

        struct Content: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Print a profile's YAML content.")
            @Argument(help: "Profile id shown by `kumo profile list`.")
            var id: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let content = try CLIRuntime.current.controller.profileContent(id: id)
                let payload = ProfileContentPayload(id: id, content: content)
                CLIRuntime.current.write(payload) { $0.content }
            }
        }

        struct Refresh: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Refresh or import a remote profile URL.")
            @Argument(help: "Remote subscription URL.")
            var url: String
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                guard let parsedURL = URL(string: url), parsedURL.scheme != nil else {
                    throw ValidationError("Invalid profile URL: \(url)")
                }
                let profile = try await CLIRuntime.current.controller.refreshProfile(from: parsedURL)
                CLIRuntime.current.write(profile) { "refreshed \($0.name)" }
            }
        }
    }

    struct Sysproxy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Control macOS system proxy.",
            subcommands: [On.self, Off.self, Set.self]
        )

        struct On: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Enable the macOS system proxy.")
            @Flag(name: .long, help: "Preview networksetup commands without changing system settings.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let commands = try await CLIRuntime.current.controller.setSystemProxy(true, dryRun: dryRun)
                writeSystemProxyCommands(commands, state: "on", dryRun: dryRun)
            }
        }

        struct Off: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable the macOS system proxy.")
            @Flag(name: .long, help: "Preview networksetup commands without changing system settings.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let commands = try await CLIRuntime.current.controller.setSystemProxy(false, dryRun: dryRun)
                writeSystemProxyCommands(commands, state: "off", dryRun: dryRun)
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Update stored system proxy settings.")

            @Option(name: .long, help: "Comma-separated bypass domains and addresses.")
            var bypass: String?
            @Option(name: .long, help: "Network service name, for example Wi-Fi.")
            var networkService: String?
            @Option(name: .long, help: "Proxy host.")
            var host: String?
            @Option(name: .long, help: "Proxy port.")
            var port: Int?
            @Option(name: .long, help: "Proxy mode: manual or pac.")
            var mode: SystemProxyMode?
            @Option(name: .long, help: "Read a JSON settings patch from a file.")
            var file: String?
            @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Preview the update without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                let hasOptions = bypass != nil || networkService != nil || host != nil || port != nil || mode != nil
                if file != nil || stdin {
                    if hasOptions {
                        throw ValidationError("Use either --file/--stdin or explicit options, not both.")
                    }
                    try validateSettingsInput(file: file, stdin: stdin)
                } else if !hasOptions {
                    throw ValidationError("Provide at least one setting or a --file/--stdin JSON patch.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let current = try controller.status().systemProxySettings ?? SystemProxySettings()
                var settings = current
                if file != nil || stdin {
                    let patch = try readSettingsPatchJSON(file: file, stdin: stdin)
                    settings = try applyingSettingsPatch(patch, to: current, name: "SystemProxySettings")
                } else {
                    if let bypass {
                        settings.bypassList = bypass
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                    if let networkService { settings.networkService = networkService }
                    if let host { settings.host = host }
                    if let port { settings.port = port }
                    if let mode { settings.mode = mode }
                }

                if dryRun {
                    CLIRuntime.current.write(settings) { _ in "[dry-run] system proxy settings not written" }
                    return
                }
                try controller.updateSystemProxySettings(settings)
                if try controller.status().systemProxyEnabled {
                    _ = try await controller.setSystemProxy(true)
                }
                CLIRuntime.current.write(settings) { _ in "system proxy settings updated" }
            }
        }
    }

    struct Service: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage Kumo service mode.",
            subcommands: [Status.self, Install.self, Uninstall.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show service mode state.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                writeServiceModeStatus(CLIRuntime.current.controller.serviceModeStatus())
            }
        }

        struct Install: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install service mode.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                writeServiceModeStatus(try CLIRuntime.current.controller.installServiceMode())
            }
        }

        struct Uninstall: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Uninstall service mode.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                writeServiceModeStatus(try CLIRuntime.current.controller.uninstallServiceMode())
            }
        }
    }

    struct Tun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage TUN state and settings.",
            subcommands: [Status.self, Enable.self, Disable.self, Settings.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show TUN state.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                write(try CLIRuntime.current.controller.tunStatus())
            }
        }

        struct Enable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Enable TUN.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                write(try await CLIRuntime.current.controller.setTunEnabled(true))
            }
        }

        struct Disable: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable TUN.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                write(try await CLIRuntime.current.controller.setTunEnabled(false))
            }
        }

        struct Settings: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show TUN settings or update them from a JSON patch.",
                discussion: "With no input, prints the current settings. Use --file <path> or --stdin with a JSON object whose keys match TunSettings; only the provided keys are changed."
            )

            @Option(name: .long, help: "Read a JSON settings patch from a file.")
            var file: String?
            @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Preview the update without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if file != nil || stdin {
                    try validateSettingsInput(file: file, stdin: stdin)
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                let current = try controller.status().runtimeSettings?.tun ?? TunSettings()

                guard file != nil || stdin else {
                    CLIRuntime.current.write(current) { tunSettingsSummary($0) }
                    return
                }

                let patch = try readSettingsPatchJSON(file: file, stdin: stdin)
                let settings = try applyingSettingsPatch(patch, to: current, name: "TunSettings")
                if dryRun {
                    CLIRuntime.current.write(settings) { "[dry-run] \(tunSettingsSummary($0))" }
                    return
                }
                _ = try await controller.applyTunSettings(settings)
                CLIRuntime.current.write(settings) { tunSettingsSummary($0) }
            }
        }

        private static func write(_ status: TunStatus) {
            CLIRuntime.current.write(status) { status in
                "enabled=\(status.isEnabled) running=\(status.isRunning) requiresService=\(status.requiresService)"
            }
        }
    }

    struct Substore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "substore",
            abstract: "Manage bundled Sub-Store resources and runtime.",
            subcommands: [Status.self, Prepare.self, Start.self, Stop.self, Restart.self]
        )

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show Sub-Store state.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let status = try await CLIRuntime.current.controller.subStoreRuntimeStatus()
                CLIRuntime.current.write(status) { status in
                    [
                        "enabled=\(status.configuration.isEnabled)",
                        "backend=\(status.isBackendRunning)",
                        "url=\(status.backendURL?.absoluteString ?? "-")",
                        "resources=\(status.resourcesInstalled)"
                    ].joined(separator: " ")
                }
            }
        }

        struct Prepare: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Prepare bundled Sub-Store resources.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let status = try CLIRuntime.current.controller.prepareSubStoreResources()
                CLIRuntime.current.write(status) { "prepared Sub-Store resources \($0.installedResourceVersion ?? "-")" }
            }
        }

        struct Start: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Start Sub-Store.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let status = try await CLIRuntime.current.controller.setSubStoreEnabled(true)
                CLIRuntime.current.write(status) { _ in "started Sub-Store" }
            }
        }

        struct Stop: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop Sub-Store.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                let status = try await CLIRuntime.current.controller.setSubStoreEnabled(false)
                CLIRuntime.current.write(status) { _ in "stopped Sub-Store" }
            }
        }

        struct Restart: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Restart Sub-Store.")
            @OptionGroup var options: CLIOptions
            mutating func run() async throws {
                try options.install()
                try await CLIRuntime.current.controller.restartSubStoreService()
                let status = try await CLIRuntime.current.controller.subStoreRuntimeStatus()
                CLIRuntime.current.write(status) { _ in "restarted Sub-Store" }
            }
        }
    }
}

private func profileFileURL(from value: String) throws -> URL {
    if let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased() {
        switch scheme {
        case "http", "https":
            throw ValidationError("Remote subscriptions use `kumo profile refresh <url>`; `kumo profile import` imports a local YAML file.")
        case "file":
            return parsed
        default:
            throw ValidationError("Unsupported profile URL scheme: \(scheme)")
        }
    }
    let path = (value as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: path) else {
        throw ValidationError("Profile file not found: \(path)")
    }
    return URL(fileURLWithPath: path)
}

private func writeSystemProxyCommands(_ commands: [ShellCommand], state: String, dryRun: Bool) {
    CLIRuntime.current.write(commands) { commands in
        let text = commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }.joined(separator: "\n")
        return dryRun ? text : "system proxy \(state)"
    }
}

private func tunSettingsSummary(_ settings: TunSettings) -> String {
    [
        "enabled=\(settings.isEnabled)",
        "stack=\(settings.stack)",
        "autoRoute=\(settings.autoRoute)",
        "autoRedirect=\(settings.autoRedirect)",
        "mtu=\(settings.mtu)",
        "device=\(settings.device ?? "-")"
    ].joined(separator: " ")
}
