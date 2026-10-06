import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show Kumo paths or runtime settings.",
            subcommands: [Path.self, List.self, Get.self, Set.self, Secret.self],
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
            subcommands: [List.self, Use.self, Delete.self, Import.self, Content.self, Refresh.self, Update.self, Edit.self],
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
                let payload = try Self.perform(controller: CLIRuntime.current.controller, id: id)
                CLIRuntime.current.write(payload) { $0.content }
            }

            /// Pre-validates the id: `KumoController.profileContent(id:)`
            /// silently falls back to the current profile for an unknown id,
            /// which would print the wrong profile instead of failing.
            static func perform(controller: KumoController, id: String) throws -> ProfileContentPayload {
                guard try controller.profiles().contains(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }
                return ProfileContentPayload(id: id, content: try controller.profileContent(id: id))
            }
        }

        struct Refresh: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Refresh a subscription in place or import a remote profile URL."
            )
            @Argument(help: "Remote subscription URL. Refreshes the matching profile in place when the URL is already known; otherwise imports a new current profile.")
            var url: String?
            @Option(name: .long, help: "Profile id shown by `kumo profile list`; refreshes it in place.")
            var id: String?
            @Flag(name: .long, help: "Fetch through the local Mihomo proxy. Requires a running core.")
            var useProxy = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if url != nil && id != nil {
                    throw ValidationError("Use either a subscription URL or --id <id>, not both.")
                }
                if url == nil && id == nil {
                    throw ValidationError("Provide a remote subscription URL or --id <id>.")
                }
                if let url {
                    _ = try Self.subscriptionURL(from: url)
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller
                if let id {
                    let report = try await Self.refreshByID(controller: controller, id: id, useProxy: useProxy)
                    CLIRuntime.current.write(report) { report in
                        let base = "refreshed \(report.profile.name) (\(report.profile.id))"
                        return report.restartedCore ? "\(base) and restarted the core" : base
                    }
                    return
                }
                let parsedURL = try Self.subscriptionURL(from: url ?? "")
                let profile = try await controller.refreshProfile(from: parsedURL, useProxy: useProxy)
                CLIRuntime.current.write(profile) { "refreshed \($0.name)" }
            }

            /// Refreshes `id` in place. When the refreshed profile is current
            /// and the core is running, the core is restarted so the new YAML
            /// takes effect, mirroring the GUI's refresh flow.
            static func refreshByID(controller: KumoController, id: String, useProxy: Bool) async throws -> ProfileRefreshReport {
                guard let existing = try controller.profiles().first(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }
                let summary = try await controller.refreshProfile(id: id, useProxy: useProxy ? true : nil)
                var restartedCore = false
                if existing.isCurrent, try controller.status().state == .running {
                    _ = try controller.restart()
                    try await controller.waitForControllerReady()
                    restartedCore = true
                }
                return ProfileRefreshReport(profile: summary, restartedCore: restartedCore)
            }

            static func subscriptionURL(from value: String) throws -> URL {
                guard let parsed = URL(string: value), parsed.scheme != nil else {
                    throw ValidationError("Invalid profile URL: \(value)")
                }
                return parsed
            }
        }

        struct Update: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Update a profile's name, subscription URL, or update preferences.",
                discussion: "Omitted fields keep their stored value. The profile YAML is not re-downloaded; use `kumo profile refresh` for that."
            )
            @Argument(help: "Profile id shown by `kumo profile list`.")
            var id: String
            @Option(name: .long, help: "Rename the profile.")
            var name: String?
            @Option(name: .long, help: "Set the subscription URL.")
            var url: String?
            @Flag(name: .long, inversion: .prefixedNo, help: "Enable or disable automatic updates.")
            var autoUpdate: Bool?
            @Flag(name: .long, inversion: .prefixedNo, help: "Fetch through the local Mihomo proxy on refresh.")
            var useProxy: Bool?
            @Flag(name: .long, help: "Preview the merged metadata without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if name == nil && url == nil && autoUpdate == nil && useProxy == nil {
                    throw ValidationError("Provide at least one of --name, --url, --auto-update, or --use-proxy.")
                }
                if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--name cannot be empty.")
                }
                if let url {
                    _ = try Self.subscriptionURL(from: url)
                }
            }

            mutating func run() async throws {
                try options.install()
                let report = try await Self.perform(
                    controller: CLIRuntime.current.controller,
                    id: id,
                    name: name,
                    urlString: url,
                    autoUpdate: autoUpdate,
                    useProxy: useProxy,
                    dryRun: dryRun
                )
                CLIRuntime.current.write(report) { report in
                    report.dryRun
                        ? "[dry-run] would update \(report.id): name=\(report.name) kind=\(report.kind.rawValue) url=\(report.remoteURL?.absoluteString ?? "-") autoUpdate=\(report.autoUpdate) useProxy=\(report.useProxy)"
                        : "updated \(report.name) (\(report.id))"
                }
            }

            /// Merges the provided flags over the stored profile metadata.
            ///
            /// Every omitted field is backfilled from the pre-read profile:
            /// `KumoController.updateProfile` takes non-optional `autoUpdate` /
            /// `useProxy` and treats a `nil` `remoteURL` as "demote to local",
            /// so a passthrough of the raw flags would silently reset stored
            /// subscription settings.
            static func perform(
                controller: KumoController,
                id: String,
                name: String?,
                urlString: String?,
                autoUpdate: Bool?,
                useProxy: Bool?,
                dryRun: Bool
            ) async throws -> ProfileUpdateReport {
                guard let existing = try controller.profiles().first(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }

                let mergedURL: URL?
                if let urlString {
                    guard !existing.isSubStoreManaged else {
                        throw ValidationError("Profile \(id) is managed by Sub-Store; use `kumo profile refresh --id \(id)` instead.")
                    }
                    mergedURL = try subscriptionURL(from: urlString)
                } else {
                    mergedURL = existing.remoteURL
                }

                let mergedName = name ?? existing.name
                let mergedAutoUpdate = autoUpdate ?? existing.autoUpdate
                let mergedUseProxy = useProxy ?? existing.useProxy
                let mergedKind: ProfileKind = mergedURL == nil
                    ? (existing.kind == .remote ? .local : existing.kind)
                    : .remote

                guard !dryRun else {
                    return ProfileUpdateReport(
                        id: id,
                        name: mergedName,
                        kind: mergedKind,
                        remoteURL: mergedURL,
                        autoUpdate: mergedAutoUpdate,
                        useProxy: mergedUseProxy,
                        dryRun: true
                    )
                }

                let summary = try controller.updateProfile(
                    id: id,
                    name: mergedName,
                    remoteURL: mergedURL,
                    autoUpdate: mergedAutoUpdate,
                    useProxy: mergedUseProxy,
                    rawYAML: try controller.profileContent(id: id)
                )
                return ProfileUpdateReport(
                    id: summary.id,
                    name: summary.name,
                    kind: summary.kind,
                    remoteURL: summary.remoteURL,
                    autoUpdate: summary.autoUpdate,
                    useProxy: summary.useProxy,
                    dryRun: false
                )
            }

            static func subscriptionURL(from value: String) throws -> URL {
                guard let parsed = URL(string: value), parsed.scheme != nil else {
                    throw ValidationError("Invalid profile URL: \(value)")
                }
                return parsed
            }
        }

        struct Edit: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Replace a profile's YAML from a file or stdin.",
                discussion: "The replacement YAML must parse as a YAML mapping; the profile's name and subscription settings are preserved."
            )
            @Argument(help: "Profile id shown by `kumo profile list`.")
            var id: String
            @Option(name: .long, help: "Read the replacement YAML from a file.")
            var file: String?
            @Flag(name: .long, help: "Read the replacement YAML from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Validate the YAML without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if file != nil && stdin {
                    throw ValidationError("Use either --file <path> or --stdin, not both.")
                }
                if file == nil && !stdin {
                    throw ValidationError("Provide --file <path> or --stdin with the replacement profile YAML.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let rawYAML = try readProfileYAML(file: file, stdin: stdin)
                let report = try Self.perform(
                    controller: CLIRuntime.current.controller,
                    id: id,
                    rawYAML: rawYAML,
                    dryRun: dryRun
                )
                CLIRuntime.current.write(report) { report in
                    report.dryRun
                        ? "[dry-run] \(report.id) YAML is valid (\(report.byteCount) bytes)"
                        : "updated \(report.name) (\(report.id))"
                }
            }

            /// Validates the replacement YAML before writing. The write path
            /// backfills name, subscription URL, auto-update and proxy
            /// preferences from the stored profile so an edit never demotes a
            /// subscription.
            static func perform(
                controller: KumoController,
                id: String,
                rawYAML: String,
                dryRun: Bool
            ) throws -> ProfileEditReport {
                guard let existing = try controller.profiles().first(where: { $0.id == id }) else {
                    throw ValidationError("Unknown profile id: \(id)")
                }
                try controller.validateProfileYAML(rawYAML)

                guard !dryRun else {
                    return ProfileEditReport(id: id, name: existing.name, dryRun: true, byteCount: rawYAML.utf8.count)
                }

                let summary = try controller.updateProfile(
                    id: id,
                    name: existing.name,
                    remoteURL: existing.remoteURL,
                    autoUpdate: existing.autoUpdate,
                    useProxy: existing.useProxy,
                    rawYAML: rawYAML
                )
                return ProfileEditReport(id: summary.id, name: summary.name, dryRun: false, byteCount: rawYAML.utf8.count)
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
            @Flag(name: .long, help: "Union the bypass list with the default bypass list.")
            var addDefaults = false
            @Option(name: .long, help: "Read a JSON settings patch from a file.")
            var file: String?
            @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Preview the update without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                let hasOptions = bypass != nil || networkService != nil || host != nil || port != nil || mode != nil || addDefaults
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
                if addDefaults {
                    settings.bypassList = mergingSystemProxyBypassDefaults(settings.bypassList)
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

/// Reads replacement profile YAML from `--file <path>` or stdin.
///
/// Callers validate that exactly one source was provided before calling this.
private func readProfileYAML(file: String?, stdin: Bool) throws -> String {
    let data: Data
    if let file {
        let path = (file as NSString).expandingTildeInPath
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ValidationError("Could not read profile file \(path): \(error.localizedDescription)")
        }
    } else if stdin {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        throw ValidationError("Provide --file <path> or --stdin with the replacement profile YAML.")
    }

    let text = String(data: data, encoding: .utf8) ?? ""
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("The profile YAML is empty.")
    }
    return text
}

private func writeSystemProxyCommands(_ commands: [ShellCommand], state: String, dryRun: Bool) {
    CLIRuntime.current.write(commands) { commands in
        let text = commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }.joined(separator: "\n")
        return dryRun ? text : "system proxy \(state)"
    }
}

/// Unions a bypass list with the default bypass list, dropping duplicates and
/// sorting the result — the same merge the GUI's "Add Defaults" button
/// performs. The defaults live in `SystemProxySettings.defaultBypassList`
/// (`KumoCoreKit`), which `SystemProxyView` and the CLI share, so there is no
/// second copy to keep in sync.
func mergingSystemProxyBypassDefaults(_ bypassList: [String]) -> [String] {
    Array(Set(bypassList + SystemProxySettings.defaultBypassList)).sorted()
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
