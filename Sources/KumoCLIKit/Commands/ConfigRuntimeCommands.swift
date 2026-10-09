import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand.Config {
    /// Top-level `CoreRuntimeSettings` keys `kumo config get` can print.
    enum SettingsKey: String, CaseIterable {
        case mixedPort
        case allowLan
        case logLevel
        case ipv6
        case findProcessMode
        case geoData

        static var validKeysList: String {
            allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print stored runtime settings.",
            discussion: "With no key, prints the whole CoreRuntimeSettings object. With a key (mixedPort, allowLan, logLevel, ipv6, findProcessMode, geoData), prints only that value. DNS, sniffer, and TUN settings have dedicated commands."
        )

        @Argument(help: "Optional settings key: \(SettingsKey.validKeysList).")
        var key: String?
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if let key, SettingsKey(rawValue: key) == nil {
                throw ValidationError("Unknown settings key '\(key)'. Valid keys: \(SettingsKey.validKeysList).")
            }
        }

        mutating func run() async throws {
            try options.install()
            let status = try CLIRuntime.current.controller.status()
            let settings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
            guard let key else {
                CLIRuntime.current.write(settings) { configRuntimeSettingsSummary($0) }
                return
            }
            guard let parsed = SettingsKey(rawValue: key) else {
                throw ValidationError("Unknown settings key '\(key)'. Valid keys: \(SettingsKey.validKeysList).")
            }
            switch parsed {
            case .mixedPort:
                CLIRuntime.current.write(settings.mixedPort) { "mixedPort=\($0)" }
            case .allowLan:
                CLIRuntime.current.write(settings.allowLAN) { "allowLan=\($0)" }
            case .logLevel:
                CLIRuntime.current.write(settings.logLevel) { "logLevel=\($0)" }
            case .ipv6:
                CLIRuntime.current.write(settings.ipv6) { "ipv6=\($0)" }
            case .findProcessMode:
                CLIRuntime.current.write(settings.findProcessMode) { "findProcessMode=\($0)" }
            case .geoData:
                CLIRuntime.current.write(settings.geoData) { configRuntimeGeoDataSummary($0) }
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Update core runtime settings.",
            discussion: "Updates mixedPort, allowLan, logLevel, ipv6, and findProcessMode, either from explicit flags or from a --file/--stdin JSON object patch (mutually exclusive). DNS, sniffer, and TUN settings keep their dedicated commands (`kumo dns`, `kumo sniffer`, `kumo tun`)."
        )

        @Option(name: .long, help: "Mixed port (1...65535).")
        var mixedPort: Int?
        @Option(name: .long, help: "Allow LAN connections: true or false.")
        var allowLan: Bool?
        @Option(name: .long, help: "Core log level: silent, error, warning, info, or debug.")
        var logLevel: String?
        @Option(name: .long, help: "Enable IPv6: true or false.")
        var ipv6: Bool?
        @Option(name: .long, help: "Process matching mode: always, strict, or off.")
        var findProcessMode: String?
        @Option(name: .long, help: "Read a JSON settings patch from a file.")
        var file: String?
        @Flag(name: .long, help: "Read a JSON settings patch from stdin.")
        var stdin = false
        @Flag(name: .long, help: "Preview the merged settings without writing.")
        var dryRun = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            let hasFlags = mixedPort != nil || allowLan != nil || logLevel != nil || ipv6 != nil || findProcessMode != nil
            if file != nil || stdin {
                if hasFlags {
                    throw ValidationError("Use either --file/--stdin or explicit options, not both.")
                }
                try validateSettingsInput(file: file, stdin: stdin)
            } else if !hasFlags {
                throw ValidationError("Provide at least one setting or a --file/--stdin JSON patch.")
            }
            if let mixedPort, !configRuntimePortRange.contains(mixedPort) {
                throw ValidationError(
                    "Invalid --mixed-port \(mixedPort). Expected a value in "
                        + "\(configRuntimePortRange.lowerBound)...\(configRuntimePortRange.upperBound)."
                )
            }
            if let logLevel, !configRuntimeLogLevels.contains(logLevel) {
                throw ValidationError(
                    "Invalid --log-level '\(logLevel)'. Valid levels: "
                        + "\(configRuntimeLogLevels.joined(separator: ", "))."
                )
            }
            if let findProcessMode, !configRuntimeFindProcessModes.contains(findProcessMode) {
                throw ValidationError(
                    "Invalid --find-process-mode '\(findProcessMode)'. Valid modes: "
                        + "\(configRuntimeFindProcessModes.joined(separator: ", "))."
                )
            }
        }

        mutating func run() async throws {
            try options.install()
            let patchData: Data? = if file != nil || stdin {
                try readSettingsPatchJSON(file: file, stdin: stdin)
            } else {
                nil
            }
            let settings = try await applyConfigRuntimeSet(
                to: CLIRuntime.current.controller,
                mixedPort: mixedPort,
                allowLan: allowLan,
                logLevel: logLevel,
                ipv6: ipv6,
                findProcessMode: findProcessMode,
                patchData: patchData,
                dryRun: dryRun
            )
            CLIRuntime.current.write(settings) { settings in
                dryRun
                    ? "[dry-run] \(configRuntimeSettingsSummary(settings))"
                    : "runtime settings updated"
            }
        }
    }

    struct Secret: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or replace the controller secret.",
            discussion: "Without --set, prints whether a secret is set; the stored value is never printed. --set stores a new secret in state.json and takes effect the next time the core starts, not on a running core."
        )

        @Option(name: .long, help: "Store a new controller secret. The value is never echoed back.")
        var set: String?
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let controller = CLIRuntime.current.controller
            if let set {
                try controller.setControllerSecret(set)
                let isSet = !set.isEmpty
                CLIRuntime.current.write(ConfigSecretReport(isSet: isSet)) { _ in
                    isSet
                        ? "controller secret updated; it takes effect the next time the core starts"
                        : "controller secret cleared; it takes effect the next time the core starts"
                }
                return
            }
            let isSet = !(try controller.status()).endpoint.secret.isEmpty
            CLIRuntime.current.write(ConfigSecretReport(isSet: isSet)) { "set=\($0.isSet)" }
        }
    }
}

/// Scalar `CoreRuntimeSettings` keys `kumo config set` owns.
let configRuntimePatchKeys: Set<String> = ["mixedPort", "allowLan", "logLevel", "ipv6", "findProcessMode"]

/// Settings groups that keep dedicated commands instead of `config set`.
let configRuntimeDedicatedCommands: [String: String] = [
    "dns": "kumo dns set",
    "sniffer": "kumo sniffer set",
    "tun": "kumo tun settings"
]

let configRuntimePortRange = 1...65535
let configRuntimeLogLevels = ["silent", "error", "warning", "info", "debug"]
let configRuntimeFindProcessModes = ["always", "strict", "off"]

/// Rejects patch keys `kumo config set` does not own.
///
/// DNS, sniffer, and TUN keep dedicated commands and get a pointer to them;
/// every key outside the scalar runtime keys is rejected as unknown.
func validateConfigRuntimePatchKeys(_ keys: [String]) throws {
    for key in keys.sorted() {
        if let command = configRuntimeDedicatedCommands[key] {
            throw ValidationError("`\(key)` settings are not part of `kumo config set`; use `\(command)`.")
        }
    }
    let unknown = Set(keys).subtracting(configRuntimePatchKeys).sorted()
    guard unknown.isEmpty else {
        let noun = unknown.count == 1 ? "key" : "keys"
        throw ValidationError(
            "Unknown \(noun) in the runtime settings patch: \(unknown.joined(separator: ", ")). "
                + "Valid keys: \(configRuntimePatchKeys.sorted().joined(separator: ", "))."
        )
    }
}

/// Merges `kumo config set` inputs onto the stored runtime settings and, unless
/// this is a dry run, writes them through `KumoController.updateRuntimeSettings`.
func applyConfigRuntimeSet(
    to controller: KumoController,
    mixedPort: Int? = nil,
    allowLan: Bool? = nil,
    logLevel: String? = nil,
    ipv6: Bool? = nil,
    findProcessMode: String? = nil,
    patchData: Data? = nil,
    dryRun: Bool = false
) async throws -> CoreRuntimeSettings {
    let status = try controller.status()
    let current = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
    let settings: CoreRuntimeSettings
    if let patchData {
        let patch = try decodeSettingsPatch(patchData, name: "CoreRuntimeSettings")
        try validateConfigRuntimePatchKeys(Array(patch.keys))
        settings = try applyingSettingsPatch(patch, to: current, name: "CoreRuntimeSettings")
    } else {
        var merged = current
        if let mixedPort { merged.mixedPort = mixedPort }
        if let allowLan { merged.allowLAN = allowLan }
        if let logLevel { merged.logLevel = logLevel }
        if let ipv6 { merged.ipv6 = ipv6 }
        if let findProcessMode { merged.findProcessMode = findProcessMode }
        settings = merged
    }
    guard !dryRun else { return settings }
    try await controller.updateRuntimeSettings(settings)
    return settings
}

func configRuntimeSettingsSummary(_ settings: CoreRuntimeSettings) -> String {
    [
        "mixedPort=\(settings.mixedPort)",
        "allowLan=\(settings.allowLAN)",
        "logLevel=\(settings.logLevel)",
        "ipv6=\(settings.ipv6)",
        "findProcessMode=\(settings.findProcessMode)"
    ].joined(separator: " ")
}

func configRuntimeGeoDataSummary(_ geoData: GeoDataSettings) -> String {
    [
        "geoIPURL=\(geoData.geoIPURL)",
        "geoSiteURL=\(geoData.geoSiteURL)",
        "mmdbURL=\(geoData.mmdbURL)",
        "asnURL=\(geoData.asnURL)",
        "autoUpdate=\(geoData.autoUpdate)",
        "updateIntervalHours=\(geoData.updateIntervalHours)",
        "usesDatMode=\(geoData.usesDatMode)"
    ].joined(separator: " ")
}
