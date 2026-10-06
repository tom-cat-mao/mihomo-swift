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
