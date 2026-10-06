import Foundation
import KumoCoreKit

struct ProviderReport: Encodable {
    var proxies: [ProxyProviderEntry]
    var rules: [RuleProviderEntry]
}

struct DoctorReport: Encodable {
    var status: CoreStatus
    var currentProfile: ProfileSummary
    var coreCandidates: [CoreCandidate]
}

public struct CLIPaths: Encodable, Equatable {
    var applicationSupportDirectory: String
    var profilesDirectory: String
    var workDirectory: String
    var logsDirectory: String
    var runtimeConfigFile: String
    var stateFile: String

    init(paths: KumoPaths) {
        self.applicationSupportDirectory = paths.applicationSupportDirectory.path
        self.profilesDirectory = paths.profilesDirectory.path
        self.workDirectory = paths.workDirectory.path
        self.logsDirectory = paths.logsDirectory.path
        self.runtimeConfigFile = paths.runtimeConfigFile.path
        self.stateFile = paths.stateFile.path
    }
}

struct CLILogEntry: Codable, Equatable {
    var createdAt: String
    var level: LogLevel
    var summary: String
}

struct CLILogCleanReport: Codable, Equatable {
    var dryRun: Bool
    var matchedFiles: Int
    var wouldRemoveFiles: Int
}

struct TimingPayload: Encodable {
    var timers: [String: Int]
    var totalMilliseconds: Int
}

struct RuleTogglePayload: Encodable, Equatable {
    var index: Int
    var isEnabled: Bool
}

struct ProfileDeleteReport: Encodable, Equatable {
    var id: String
    var dryRun: Bool
    var wasCurrent: Bool
}

struct ProfileContentPayload: Encodable, Equatable {
    var id: String
    var content: String
}

struct ProfileRefreshReport: Encodable, Equatable {
    var profile: ProfileSummary
    var restartedCore: Bool
}

/// Merged profile metadata a `profile update` writes. Also returned by
/// `--dry-run`, where nothing is written but the planned values are reported.
struct ProfileUpdateReport: Encodable, Equatable {
    var id: String
    var name: String
    var kind: ProfileKind
    var remoteURL: URL?
    var autoUpdate: Bool
    var useProxy: Bool
    var dryRun: Bool
}

struct ProfileEditReport: Encodable, Equatable {
    var id: String
    var name: String
    var dryRun: Bool
    var byteCount: Int
}

struct ProxyDelayReport: Encodable, Equatable {
    var proxy: String
    var url: String?
    var delay: Int?
}

struct ProvidersUpdateReport: Encodable, Equatable {
    var proxyProvider: String?
    var ruleProvider: String?
    var geoData: Bool
}

/// Reports whether a controller secret is stored; the secret value itself is
/// never part of CLI output.
struct ConfigSecretReport: Encodable, Equatable {
    var isSet: Bool
}

struct AgentActionReport: Encodable, Equatable {
    var action: String
    var label: String
    var plistPath: String
    var socketPath: String
    var dryRun: Bool
    var status: ServiceModeStatus
}

struct OverrideListEntry: Encodable, Equatable {
    var index: Int
    var id: String
    var name: String
    var format: String
    var kind: String
    var isGlobal: Bool
    var remoteURL: String?
}

struct OverrideContentPayload: Encodable, Equatable {
    var id: String
    var content: String
}

struct OverrideMutationReport: Encodable, Equatable {
    var id: String?
    var name: String
    var format: String
    var kind: String
    var isGlobal: Bool
    var dryRun: Bool
    var warnings: [String]
    var restartRequested: Bool
    var restarted: Bool
}

struct OverrideDeleteReport: Encodable, Equatable {
    var id: String
    var name: String
    var dryRun: Bool
    var restartRequested: Bool
    var restarted: Bool
}

struct OverrideReorderReport: Encodable, Equatable {
    var ids: [String]
    var restartRequested: Bool
    var restarted: Bool
}

/// The user-facing `UserPreferences` keys printed by `prefs get`.
///
/// `updateManifestURL` is intentionally absent: it is an internal
/// update-channel override, not a user preference, and `prefs set` preserves
/// it untouched because it round-trips the whole stored value.
struct PrefsSnapshot: Encodable, Equatable {
    var launchAtLogin: Bool
    var hideMenuBarIcon: Bool
    var quitOnLastWindowClose: Bool
    var keepCoreRunningOnQuit: Bool
    var updateChannel: AppUpdateChannel
    var appLanguage: String?
    var hasCompletedOnboarding: Bool

    init(_ preferences: UserPreferences) {
        self.launchAtLogin = preferences.launchAtLogin
        self.hideMenuBarIcon = preferences.hideMenuBarIcon
        self.quitOnLastWindowClose = preferences.quitOnLastWindowClose
        self.keepCoreRunningOnQuit = preferences.keepCoreRunningOnQuit
        self.updateChannel = preferences.updateChannel
        self.appLanguage = preferences.appLanguage
        self.hasCompletedOnboarding = preferences.hasCompletedOnboarding
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case hideMenuBarIcon
        case quitOnLastWindowClose
        case keepCoreRunningOnQuit
        case updateChannel
        case appLanguage
        case hasCompletedOnboarding
    }

    /// Encodes `appLanguage` as an explicit null when the preference follows
    /// the system language, so the JSON shape does not change with the value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(hideMenuBarIcon, forKey: .hideMenuBarIcon)
        try container.encode(quitOnLastWindowClose, forKey: .quitOnLastWindowClose)
        try container.encode(keepCoreRunningOnQuit, forKey: .keepCoreRunningOnQuit)
        try container.encode(updateChannel, forKey: .updateChannel)
        if let appLanguage {
            try container.encode(appLanguage, forKey: .appLanguage)
        } else {
            try container.encodeNil(forKey: .appLanguage)
        }
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }
}

/// Result of `prefs set`: the parsed key/value, the merged preferences, and
/// any deferred-effect notes for the key.
struct PrefsSetReport: Encodable, Equatable {
    var key: String
    var value: String
    var dryRun: Bool
    var notes: [String]
    var preferences: PrefsSnapshot
}

/// Result of a `cli-link install|uninstall` run (or its `--dry-run` preview).
struct CLILinkActionReport: Encodable, Equatable {
    var action: String
    var dryRun: Bool
    var status: CLILinkStatus
}

/// One provider's outcome in a `providers update --all` run.
struct ProviderUpdateResult: Encodable, Equatable {
    var kind: String
    var name: String
    var updated: Bool
    var error: String?
}

/// Full report for `providers update --all`. Provider failures are collected
/// instead of aborting the loop, so one broken provider cannot hide the rest.
struct ProvidersUpdateAllReport: Encodable, Equatable {
    var results: [ProviderUpdateResult]
    var updated: Int
    var failed: Int
    var geoData: Bool
}
