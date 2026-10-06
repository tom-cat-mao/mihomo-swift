import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Prefs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or update Kumo GUI preferences.",
            subcommands: [Get.self, Set.self],
            defaultSubcommand: Get.self
        )

        /// The preferences keys the CLI exposes.
        ///
        /// `updateManifestURL` is deliberately absent: it is an internal
        /// update-channel override, not a user preference. Reads and writes
        /// still round-trip the whole `UserPreferences` value, so the CLI
        /// never clobbers a key it does not display.
        enum Key: String, CaseIterable {
            case launchAtLogin
            case hideMenuBarIcon
            case quitOnLastWindowClose
            case keepCoreRunningOnQuit
            case updateChannel
            case appLanguage
            case hasCompletedOnboarding

            static var validKeysList: String {
                allCases.map(\.rawValue).joined(separator: ", ")
            }
        }

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print stored GUI preferences.",
                discussion: "With no key, prints the whole preference set. With a key (\(Key.validKeysList)), prints only that value."
            )

            @Argument(help: "Optional preferences key: \(Key.validKeysList).")
            var key: String?
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if let key, Key(rawValue: key) == nil {
                    throw ValidationError("Unknown preferences key '\(key)'. Valid keys: \(Key.validKeysList).")
                }
            }

            mutating func run() async throws {
                try options.install()
                let preferences = CLIRuntime.current.controller.userPreferences()
                guard let key else {
                    let snapshot = PrefsSnapshot(preferences)
                    CLIRuntime.current.write(snapshot) { prefsSnapshotSummary($0) }
                    return
                }
                guard let parsed = Key(rawValue: key) else {
                    throw ValidationError("Unknown preferences key '\(key)'. Valid keys: \(Key.validKeysList).")
                }
                switch parsed {
                case .launchAtLogin:
                    CLIRuntime.current.write(preferences.launchAtLogin) { "launchAtLogin=\($0)" }
                case .hideMenuBarIcon:
                    CLIRuntime.current.write(preferences.hideMenuBarIcon) { "hideMenuBarIcon=\($0)" }
                case .quitOnLastWindowClose:
                    CLIRuntime.current.write(preferences.quitOnLastWindowClose) { "quitOnLastWindowClose=\($0)" }
                case .keepCoreRunningOnQuit:
                    CLIRuntime.current.write(preferences.keepCoreRunningOnQuit) { "keepCoreRunningOnQuit=\($0)" }
                case .updateChannel:
                    CLIRuntime.current.write(preferences.updateChannel) { "updateChannel=\($0.rawValue)" }
                case .appLanguage:
                    CLIRuntime.current.write(preferences.appLanguage) { "appLanguage=\($0 ?? "system")" }
                case .hasCompletedOnboarding:
                    CLIRuntime.current.write(preferences.hasCompletedOnboarding) { "hasCompletedOnboarding=\($0)" }
                }
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Update one GUI preference.",
                discussion: "Reads the stored preferences, changes only the given key, and writes the whole set back, so other keys (including keys this command does not expose) keep their values. Booleans are strict true|false, updateChannel is stable|beta, and appLanguage is a BCP-47 tag or system to follow the system language. --dry-run prints the merged preferences without writing."
            )

            @Argument(help: "Preferences key: \(Key.validKeysList).")
            var key: String
            @Argument(help: "New value: true|false, stable|beta, or a BCP-47 language tag such as en or zh-Hans (system restores the system language).")
            var value: String
            @Flag(name: .long, help: "Preview the merged preferences without writing.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                guard let parsed = Key(rawValue: key) else {
                    throw ValidationError("Unknown preferences key '\(key)'. Valid keys: \(Key.validKeysList).")
                }
                _ = try parsePrefsValue(value, for: parsed)
            }

            mutating func run() async throws {
                try options.install()
                let report = try applyPrefsSet(
                    to: CLIRuntime.current.controller,
                    key: key,
                    rawValue: value,
                    dryRun: dryRun
                )
                CLIRuntime.current.write(report) { prefsSetText($0) }
            }
        }
    }
}

/// A validated `prefs set` value, typed by its key.
enum PrefsValue: Equatable {
    case boolean(Bool)
    case updateChannel(AppUpdateChannel)
    case appLanguage(String?)

    var displayString: String {
        switch self {
        case .boolean(let value): value ? "true" : "false"
        case .updateChannel(let channel): channel.rawValue
        case .appLanguage(let language): language ?? "system"
        }
    }
}

func parsePrefsValue(_ raw: String, for key: KumoCommand.Prefs.Key) throws -> PrefsValue {
    switch key {
    case .launchAtLogin, .hideMenuBarIcon, .quitOnLastWindowClose, .keepCoreRunningOnQuit, .hasCompletedOnboarding:
        // Boolean preferences are strict: no yes/no/1/0 aliases, so a typo
        // can never flip a lifecycle preference by accident.
        switch raw {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        default:
            throw ValidationError("Invalid value '\(raw)' for \(key.rawValue). Expected true or false.")
        }
    case .updateChannel:
        guard let channel = AppUpdateChannel(rawValue: raw) else {
            let channels = AppUpdateChannel.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Invalid value '\(raw)' for updateChannel. Valid channels: \(channels).")
        }
        return .updateChannel(channel)
    case .appLanguage:
        return .appLanguage(try parseAppLanguageTag(raw))
    }
}

/// Accepts a BCP-47 language tag ("en", "zh-Hans", "pt-BR") or "system" for
/// the `nil` follow-the-system-language preference.
func parseAppLanguageTag(_ raw: String) throws -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased() == "system" {
        return nil
    }
    let pattern = "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"
    guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
        throw ValidationError(
            "Invalid value '\(raw)' for appLanguage. Expected a BCP-47 language tag such as en or zh-Hans, "
                + "or system to follow the system language."
        )
    }
    return trimmed
}

func applyPrefsValue(_ value: PrefsValue, for key: KumoCommand.Prefs.Key, to preferences: inout UserPreferences) throws {
    switch value {
    case .boolean(let flag):
        switch key {
        case .launchAtLogin: preferences.launchAtLogin = flag
        case .hideMenuBarIcon: preferences.hideMenuBarIcon = flag
        case .quitOnLastWindowClose: preferences.quitOnLastWindowClose = flag
        case .keepCoreRunningOnQuit: preferences.keepCoreRunningOnQuit = flag
        case .hasCompletedOnboarding: preferences.hasCompletedOnboarding = flag
        case .updateChannel, .appLanguage:
            throw ValidationError("Invalid boolean value for \(key.rawValue).")
        }
    case .updateChannel(let channel):
        guard key == .updateChannel else {
            throw ValidationError("Invalid channel value for \(key.rawValue).")
        }
        preferences.updateChannel = channel
    case .appLanguage(let language):
        guard key == .appLanguage else {
            throw ValidationError("Invalid language value for \(key.rawValue).")
        }
        preferences.appLanguage = language
    }
}

/// Merges one `prefs set` key/value onto the stored preferences and, unless
/// this is a dry run, writes the whole set back. Every other key — including
/// `updateManifestURL`, which the CLI does not expose — keeps its stored value.
func applyPrefsSet(
    to controller: KumoController,
    key rawKey: String,
    rawValue: String,
    dryRun: Bool
) throws -> PrefsSetReport {
    guard let key = KumoCommand.Prefs.Key(rawValue: rawKey) else {
        throw ValidationError("Unknown preferences key '\(rawKey)'. Valid keys: \(KumoCommand.Prefs.Key.validKeysList).")
    }
    let value = try parsePrefsValue(rawValue, for: key)
    var preferences = controller.userPreferences()
    try applyPrefsValue(value, for: key, to: &preferences)
    if !dryRun {
        try controller.updateUserPreferences(preferences)
    }
    return PrefsSetReport(
        key: key.rawValue,
        value: value.displayString,
        dryRun: dryRun,
        notes: prefsSetNotes(for: key),
        preferences: PrefsSnapshot(preferences)
    )
}

/// Lifecycle notes attached to the keys whose effect is deferred or GUI-only.
func prefsSetNotes(for key: KumoCommand.Prefs.Key) -> [String] {
    switch key {
    case .launchAtLogin:
        ["applies on the next GUI launch; the CLI does not register the login item"]
    case .keepCoreRunningOnQuit:
        ["takes effect on the next GUI quit"]
    case .hideMenuBarIcon:
        ["GUI-only preference; the CLI does not change the menu bar icon"]
    case .hasCompletedOnboarding:
        ["settable for recovery scenarios; the GUI re-opens onboarding when it is false"]
    case .quitOnLastWindowClose, .updateChannel, .appLanguage:
        []
    }
}

func prefsSnapshotSummary(_ preferences: PrefsSnapshot) -> String {
    [
        "launchAtLogin=\(preferences.launchAtLogin)",
        "hideMenuBarIcon=\(preferences.hideMenuBarIcon)",
        "quitOnLastWindowClose=\(preferences.quitOnLastWindowClose)",
        "keepCoreRunningOnQuit=\(preferences.keepCoreRunningOnQuit)",
        "updateChannel=\(preferences.updateChannel.rawValue)",
        "appLanguage=\(preferences.appLanguage ?? "system")",
        "hasCompletedOnboarding=\(preferences.hasCompletedOnboarding)"
    ].joined(separator: " ")
}

func prefsSetText(_ report: PrefsSetReport) -> String {
    var lines = [
        report.dryRun
            ? "[dry-run] would set \(report.key)=\(report.value)"
            : "updated \(report.key)=\(report.value)"
    ]
    if report.dryRun {
        lines.append(prefsSnapshotSummary(report.preferences))
    }
    lines.append(contentsOf: report.notes.map { "note: \($0)" })
    return lines.joined(separator: "\n")
}
