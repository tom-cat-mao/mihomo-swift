import ArgumentParser
import Foundation
import KumoCoreKit

/// Versioned, machine-readable discovery surface for coding agents.
///
/// The command tree and usage strings come from ArgumentParser. This registry
/// only adds semantics that the parser cannot know: access level, risk,
/// non-mutating validation, and output stability. A completeness test prevents
/// a newly registered command from shipping without those semantics.
struct KumoCapabilities: Encodable, Equatable {
    static let protocolVersion = "1.1"

    let protocolVersion: String
    let cliVersion: String
    let envelope: Envelope
    let capabilities: FeatureIndex
    let globalParameters: [Parameter]
    let commands: [Command]
    let promptPages: [String]

    struct Envelope: Encodable, Equatable {
        let keys = ["ok", "data", "error"]
        let successExitCode = 0
        let failureExitCode = 1
        let streamingFormat = "ndjson"
    }

    struct FeatureIndex: Encodable, Equatable {
        let read: [String]
        let write: [String]
        let protected: [String]
        let dryRun: [String]
        let validate: [String]
        let rollback: [String]
    }

    struct Command: Encodable, Equatable {
        let path: String
        let usage: String
        let summary: String
        let aliases: [String]
        let access: Access
        let risk: Risk
        let outputStability: OutputStability
        let supportsDryRun: Bool
        let supportsValidate: Bool
        let supportsRollback: Bool
        let parameters: [Parameter]
    }

    struct Parameter: Encodable, Equatable {
        let name: String
        let kind: ParameterKind
        let valueName: String?
        let isRequired: Bool
        let isRepeating: Bool
        let acceptedValues: [String]
        let summary: String
    }

    enum Access: String, Encodable {
        case read
        case write
        case protected
    }

    enum Risk: String, Encodable {
        case low
        case medium
        case high
    }

    enum ParameterKind: String, Encodable {
        case argument
        case option
        case flag
    }

    enum OutputStability: String, Encodable {
        /// Stable JSON payload inside the ordinary `{ok,data,error}` envelope.
        case stable
        /// A stable envelope per line; consumers must read NDJSON.
        case stableStream
        /// Human-oriented text; do not build automation on its layout.
        case humanText
    }
}

enum AgentCommandCatalog {
    private struct Descriptor {
        var access: KumoCapabilities.Access
        var risk: KumoCapabilities.Risk = .low
        var output: KumoCapabilities.OutputStability = .stable
        var dryRun = false
        var validate = false
        var rollback = false
        var parameters: [KumoCapabilities.Parameter] = []

        static func read(
            output: KumoCapabilities.OutputStability = .stable,
            dryRun: Bool = false,
            validate: Bool = false,
            rollback: Bool = false,
            parameters: [KumoCapabilities.Parameter] = []
        ) -> Descriptor {
            Descriptor(
                access: .read,
                output: output,
                dryRun: dryRun,
                validate: validate,
                rollback: rollback,
                parameters: parameters
            )
        }

        static func write(
            risk: KumoCapabilities.Risk = .medium,
            protected: Bool = false,
            dryRun: Bool = false,
            validate: Bool = false,
            rollback: Bool = false,
            parameters: [KumoCapabilities.Parameter] = []
        ) -> Descriptor {
            Descriptor(
                access: protected ? .protected : .write,
                risk: risk,
                dryRun: dryRun,
                validate: validate,
                rollback: rollback,
                parameters: parameters
            )
        }
    }

    static func capabilities() -> KumoCapabilities {
        let commands = entries.map { entry in
            let descriptor = descriptors[entry.commandPath]!
            let defaultChild = entry.children.first { $0.name == entry.defaultSubcommandName }
            let defaultDescriptor = defaultChild.flatMap { descriptors[$0.commandPath] }
            let usage = defaultChild.map { child in
                KumoCommand.usageString(for: child.type).replacingOccurrences(
                    of: "kumo \(child.commandPath)",
                    with: "kumo \(entry.commandPath)"
                )
            } ?? KumoCommand.usageString(for: entry.type)
            return KumoCapabilities.Command(
                path: entry.commandPath,
                usage: usage,
                summary: entry.abstract,
                aliases: entry.aliases,
                access: descriptor.access,
                risk: descriptor.risk,
                outputStability: descriptor.output,
                supportsDryRun: descriptor.dryRun,
                supportsValidate: descriptor.validate,
                supportsRollback: descriptor.rollback,
                parameters: descriptor.parameters.isEmpty ? defaultDescriptor?.parameters ?? [] : descriptor.parameters
            )
        }
        return KumoCapabilities(
            protocolVersion: KumoCapabilities.protocolVersion,
            cliVersion: KumoCommand.configuration.version,
            envelope: KumoCapabilities.Envelope(),
            capabilities: KumoCapabilities.FeatureIndex(
                read: commands.filter { $0.access == .read }.map(\.path),
                write: commands.filter { $0.access == .write }.map(\.path),
                protected: commands.filter { $0.access == .protected }.map(\.path),
                dryRun: commands.filter(\.supportsDryRun).map(\.path),
                validate: commands.filter(\.supportsValidate).map(\.path),
                rollback: commands.filter(\.supportsRollback).map(\.path)
            ),
            globalParameters: globalParameters,
            commands: commands,
            promptPages: AgentGuidance.guides.map(\.page)
        )
    }

    /// Runnable command nodes, including default-subcommand parents and the
    /// dual-mode `connections` command. Non-runnable grouping nodes are absent.
    static var entries: [CommandIndex.Entry] {
        CommandIndex.all.filter {
            $0.isLeaf || $0.hasDefaultSubcommand || $0.commandPath == "connections"
        }
    }

    static var descriptorPaths: Set<String> {
        Set(descriptors.keys)
    }

    static var globalParameters: [KumoCapabilities.Parameter] {
        [
            flag("--json", "Write machine-readable JSON."),
            option("--color", "color", "Color output.", values: ["always", "auto", "never"]),
            option("--loglevel", "level", "Diagnostic log level.", values: ["silent", "error", "warn", "notice", "http", "info", "verbose", "silly"]),
            flag("--silent", "Suppress successful text output."),
            flag("--verbose", "Show verbose diagnostics."),
            flag("-d", "Show info diagnostics."),
            option("--logs-dir", "path", "Override the CLI debug log directory."),
            option("--logs-max", "count", "Maximum retained CLI debug logs; 0 disables them."),
            flag("--timing", "Write timing diagnostics."),
            option("--progress", "mode", "Progress output.", values: ["true", "false", "auto"])
        ]
    }

    // Add future commands here when they are added to KumoCommand's tree. A
    // protocol test requires exactly one descriptor per runnable command.
    private static let descriptors: [String: Descriptor] = [
        "capabilities": .read(),
        "prompt": .read(parameters: [
            argument("page", required: false, summary: "Page listed by `kumo prompt --list`."),
            argument("intent", required: false, summary: "Intent id; defaults to the page's first intent."),
            flag("--list", "List pages and their intent ids.")
        ]),
        "status": .read(),
        "start": .write(parameters: [
            option("--core", "path", "Use a specific Mihomo core executable."),
            flag("--resolve-ports", "Explicitly move occupied listeners to free ports.")
        ]),
        "stop": .write(),
        "restart": .write(parameters: [option("--core", "path", "Use a specific Mihomo core executable.")]),
        "mode": .write(parameters: [argument("mode", values: ["rule", "global", "direct"], summary: "Outbound mode.")]),
        "proxies": .read(parameters: [flag("--geo", "Resolve node countries through the public ipwho.is service.")]),
        "select": .write(parameters: [argument("group"), argument("proxy")]),
        "topology": .read(parameters: [flag("--issues", "Print only unresolved configuration references.")]),
        "rules": .read(),
        "rules list": .read(),
        "rules enable": .write(parameters: [argument("index")]),
        "rules disable": .write(parameters: [argument("index")]),
        "test": .read(parameters: [argument("target"), option("--url", "url", "Test URL for a single proxy.")]),
        "logs": .read(output: .stableStream),
        "logs runtime": .read(output: .stableStream, parameters: [
            option("--limit", "count", "Maximum number of log lines."),
            option("--level", "level", "Minimum log level."),
            flag("--follow", "Stream entries as NDJSON with --json.")
        ]),
        "logs cli": .read(parameters: [option("--limit", "count", "Maximum entries."), option("--level", "level", "Minimum log level.")]),
        "logs path": .read(),
        "logs clean": .write(dryRun: true),
        "traffic": .read(output: .stableStream, parameters: [flag("--watch", "Stream traffic snapshots (required).")]),
        "connections": .write(risk: .high, parameters: [option("--close", "id", "Close one connection."), flag("--close-all", "Close every active connection.")]),
        "connections close": .write(risk: .high, parameters: [option("--ids", "id1,id2,...", "Close specific connection ids.", required: true)]),
        "providers": .read(),
        "providers overview": .read(),
        "providers update": .write(parameters: [
            option("--proxy", "name", "Update one proxy provider."),
            option("--rule", "name", "Update one rule provider."),
            flag("--all", "Update every proxy and rule provider."),
            flag("--geo", "Upgrade GeoIP and GeoSite data.")
        ]),
        "runtime-events": .read(parameters: [option("--limit", "count", "Maximum number of events.")]),
        "doctor": .read(),
        "config": .read(),
        "config path": .read(),
        "config list": .read(),
        "config get": .read(parameters: [argument("key", required: false, values: ["mixedPort", "allowLan", "logLevel", "ipv6", "findProcessMode", "geoData"])]),
        "config set": .write(dryRun: true, validate: true, parameters: [
            option("--mixed-port", "port", "Mixed port (1...65535)."),
            option("--allow-lan", "bool", "Allow LAN connections.", values: ["true", "false"]),
            option("--log-level", "level", "Core log level.", values: ["silent", "error", "warning", "info", "debug"]),
            option("--ipv6", "bool", "Enable IPv6.", values: ["true", "false"]),
            option("--find-process-mode", "mode", "Process matching mode.", values: ["always", "strict", "off"]),
            option("--file", "path", "Read a JSON settings patch."),
            flag("--stdin", "Read a JSON settings patch from stdin."),
            dryRunFlag
        ]),
        "config diff": .read(dryRun: true, parameters: configurationCandidateParameters),
        "config validate": .read(dryRun: true, validate: true, parameters: configurationCandidateParameters),
        "config apply": .write(validate: true, rollback: true, parameters: configurationCandidateParameters),
        "config rollback": .write(rollback: true),
        "config secret": .write(parameters: [option("--set", "secret", "Replace the controller secret; never echoed.")]),
        "backup export": .write(parameters: [argument("path")]),
        "backup import": .write(risk: .high, parameters: [argument("path")]),
        "core install": .write(),
        "profile": .read(),
        "profile list": .read(),
        "profile use": .write(parameters: [argument("id")]),
        "profile delete": .write(risk: .high, dryRun: true, parameters: [argument("id"), dryRunFlag]),
        "profile import": .write(parameters: [argument("url", summary: "Local profile path or file URL.")]),
        "profile content": .read(parameters: [argument("id")]),
        "profile groups": .read(parameters: [argument("id")]),
        "profile nodes": .read(parameters: [argument("id")]),
        "profile refresh": .write(parameters: [
            argument("url", required: false, summary: "Remote subscription URL; use --id instead to refresh by id."),
            option("--id", "id", "Refresh this profile in place."),
            flag("--use-proxy", "Fetch through the running Mihomo proxy.")
        ]),
        "profile update": .write(dryRun: true, validate: true, parameters: [
            argument("id"), option("--name", "name", "Rename the profile."), option("--url", "url", "Set the subscription URL."),
            flag("--auto-update", "Enable automatic updates."), flag("--no-auto-update", "Disable automatic updates."),
            flag("--use-proxy", "Use the proxy on refresh."), flag("--no-use-proxy", "Do not use the proxy on refresh."), dryRunFlag
        ]),
        "profile edit": .write(dryRun: true, validate: true, parameters: [
            argument("id"), option("--file", "path", "Read replacement YAML."), flag("--stdin", "Read replacement YAML from stdin."), dryRunFlag
        ]),
        "override": .read(),
        "override list": .read(),
        "override content": .read(parameters: [argument("id")]),
        "override add": .write(dryRun: true, validate: true, parameters: [
            option("--file", "path", "Read a local override."), flag("--stdin", "Read a local override from stdin."),
            option("--url", "url", "Fetch a remote override directly."), option("--name", "name", "Override name."),
            option("--format", "format", "Override format.", values: ["yaml", "js"]), flag("--global", "Store the global flag (no runtime effect yet)."),
            flag("--restart", "Restart a running core to apply immediately."), dryRunFlag
        ]),
        "override update": .write(parameters: [
            argument("id"), option("--file", "path", "Read the new override body."), flag("--stdin", "Read the new body from stdin."), flag("--restart", "Restart a running core.")
        ]),
        "override delete": .write(risk: .high, dryRun: true, parameters: [argument("id"), flag("--restart", "Restart a running core."), dryRunFlag]),
        "override reorder": .write(parameters: [option("--ids", "id1,id2,...", "Override ids in merge order.", required: true), flag("--restart", "Restart a running core.")]),
        "prefs": .read(),
        "prefs get": .read(parameters: [argument("key", required: false)]),
        "prefs set": .write(dryRun: true, validate: true, parameters: [argument("key"), argument("value"), dryRunFlag]),
        "dns": .read(),
        "dns show": .read(),
        "dns enable": .write(),
        "dns disable": .write(),
        "dns set": .write(dryRun: true, validate: true, parameters: [option("--file", "path", "Read a DNS JSON patch."), flag("--stdin", "Read a DNS JSON patch from stdin."), dryRunFlag]),
        "sniffer": .read(),
        "sniffer show": .read(),
        "sniffer enable": .write(),
        "sniffer disable": .write(),
        "sniffer set": .write(dryRun: true, validate: true, parameters: [option("--file", "path", "Read a sniffer JSON patch."), flag("--stdin", "Read a sniffer JSON patch from stdin."), dryRunFlag]),
        "sysproxy status": .read(),
        "sysproxy on": .write(protected: true, dryRun: true, parameters: [dryRunFlag]),
        "sysproxy off": .write(protected: true, dryRun: true, parameters: [dryRunFlag]),
        "sysproxy reclaim": .write(protected: true, dryRun: true, parameters: [dryRunFlag]),
        "sysproxy set": .write(protected: true, dryRun: true, validate: true, parameters: [
            option("--bypass", "comma-list", "Bypass domains and addresses."), option("--network-service", "name", "macOS network service."),
            option("--host", "host", "Proxy host."), option("--port", "port", "Proxy port."), option("--mode", "mode", "Proxy mode.", values: ["manual", "pac"]),
            flag("--add-defaults", "Union bypass entries with Kumo's defaults."), option("--file", "path", "Read a system-proxy JSON patch."),
            flag("--stdin", "Read a system-proxy JSON patch from stdin."), dryRunFlag
        ]),
        "cli-link": .read(),
        "cli-link status": .read(),
        "cli-link install": .write(protected: true, dryRun: true, parameters: [dryRunFlag]),
        "cli-link uninstall": .write(risk: .high, protected: true, dryRun: true, parameters: [dryRunFlag]),
        "service status": .read(),
        "service install": .write(protected: true),
        "service uninstall": .write(risk: .high, protected: true),
        "tun status": .read(),
        "tun enable": .write(protected: true),
        "tun disable": .write(protected: true),
        "tun settings": .write(dryRun: true, validate: true, parameters: [option("--file", "path", "Read a TUN JSON patch."), flag("--stdin", "Read a TUN JSON patch from stdin."), dryRunFlag]),
        "agent status": .read(),
        "agent install": .write(dryRun: true, parameters: [dryRunFlag]),
        "agent uninstall": .write(risk: .high, dryRun: true, parameters: [dryRunFlag]),
        "agent migrate": .write(dryRun: true, validate: true, parameters: [dryRunFlag]),
        "substore status": .read(),
        "substore prepare": .write(),
        "substore start": .write(),
        "substore stop": .write(),
        "substore restart": .write(),
        "substore subscriptions": .read(),
        "substore collections": .read(),
        "substore files": .read(),
        "substore modules": .read(),
        "substore content": .read(parameters: [argument("name"), option("--kind", "kind", "Restrict entry kind.", values: ["subscription", "collection", "file"])]),
        "substore preview": .read(parameters: [argument("name"), option("--kind", "kind", "Restrict entry kind.", values: ["subscription", "collection", "file"])]),
        "substore import": .write(parameters: [argument("name-or-path"), option("--name", "profile-name", "Stored profile name."), flag("--use-proxy", "Download through the running Mihomo proxy.")]),
        "substore settings": .read(),
        "substore logs": .read(parameters: [option("--limit", "count", "Maximum log entries.")]),
        "skills status": .read(parameters: skillSelectionParameters),
        "skills install": .write(dryRun: true, parameters: skillSelectionParameters + [dryRunFlag, flag("--force", "Replace an existing untracked skill directory.")]),
        "skills uninstall": .write(risk: .high, dryRun: true, parameters: skillSelectionParameters + [dryRunFlag]),
        "completion": .read(output: .humanText, parameters: [argument("shell", required: false, values: ["zsh", "bash", "fish"])]),
        "help": .read(output: .humanText, parameters: [argument("terms", required: false, repeating: true)])
    ]

    private static var configurationCandidateParameters: [KumoCapabilities.Parameter] {
        [
            option("--file", "path", "Read candidate current-profile YAML."),
            flag("--stdin", "Read candidate current-profile YAML from stdin.")
        ]
    }

    private static var skillSelectionParameters: [KumoCapabilities.Parameter] {
        [
            option("--agent", "agent", "Agent target.", values: ["cursor", "claude", "codex", "gemini", "agents", "all"]),
            option("--scope", "scope", "Installation scope.", values: ["global", "project"])
        ]
    }

    private static var dryRunFlag: KumoCapabilities.Parameter {
        flag("--dry-run", "Preview or validate without mutating state.")
    }

    private static func argument(
        _ name: String,
        required: Bool = true,
        repeating: Bool = false,
        values: [String] = [],
        summary: String = ""
    ) -> KumoCapabilities.Parameter {
        KumoCapabilities.Parameter(name: name, kind: .argument, valueName: name, isRequired: required, isRepeating: repeating, acceptedValues: values, summary: summary)
    }

    private static func option(
        _ name: String,
        _ valueName: String,
        _ summary: String,
        required: Bool = false,
        values: [String] = []
    ) -> KumoCapabilities.Parameter {
        KumoCapabilities.Parameter(name: name, kind: .option, valueName: valueName, isRequired: required, isRepeating: false, acceptedValues: values, summary: summary)
    }

    private static func flag(_ name: String, _ summary: String) -> KumoCapabilities.Parameter {
        KumoCapabilities.Parameter(name: name, kind: .flag, valueName: nil, isRequired: false, isRepeating: false, acceptedValues: [], summary: summary)
    }
}

extension KumoCommand {
    struct Capabilities: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Describe the versioned agent protocol and every runnable command.",
            discussion: "Returns access, risk, parameters, output stability, dry-run, validation, and explicit configuration rollback support."
        )

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let report = AgentCommandCatalog.capabilities()
            CLIRuntime.current.write(report) { report in
                [
                    "protocol=\(report.protocolVersion) cli=\(report.cliVersion)",
                    "commands=\(report.commands.count) read=\(report.capabilities.read.count) write=\(report.capabilities.write.count) protected=\(report.capabilities.protected.count)",
                    "dryRun=\(report.capabilities.dryRun.count) validate=\(report.capabilities.validate.count) rollback=\(report.capabilities.rollback.count)",
                    "Use `kumo prompt <page> [intent]` for task-oriented guidance."
                ].joined(separator: "\n")
            }
        }
    }
}
