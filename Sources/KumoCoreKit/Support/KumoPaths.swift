import Foundation

public struct KumoPaths: Sendable {
    /// Default launchd label of the user-level agent tier ("kumod"). The
    /// effective label is the `userAgentLabel` instance property, which a dev
    /// instance can override with `KUMO_AGENT_LABEL`.
    public static let userAgentLabel = "io.kumo.KumoAgent"

    /// Opt-in environment overrides that let a dev instance run beside the
    /// production install. Unset, blank or invalid values fall back to the
    /// production defaults byte-for-byte.
    ///
    /// `KUMO_APP_SUPPORT_DIR` replaces the default app-support root and only
    /// applies when no explicit directory is injected. `KUMO_AGENT_LABEL`
    /// replaces the user-agent launchd label (and therefore the plist file
    /// name and launchctl job) so a dev tier is fully disjoint.
    public static let appSupportDirectoryEnvKey = "KUMO_APP_SUPPORT_DIR"
    public static let userAgentLabelEnvKey = "KUMO_AGENT_LABEL"

    public var applicationSupportDirectory: URL
    /// Where the user-level LaunchAgent plist is written. Injectable so tests
    /// stay off the real `~/Library/LaunchAgents`.
    public var launchAgentsDirectory: URL
    /// Effective launchd label of the user-level agent tier. Defaults to
    /// `KumoPaths.userAgentLabel`; a valid `KUMO_AGENT_LABEL` overrides it.
    public var userAgentLabel: String

    /// - Parameter environment: process environment the opt-in dev overrides
    ///   are read from. Injectable so tests never mutate the real process
    ///   environment.
    public init(
        applicationSupportDirectory: URL? = nil,
        launchAgentsDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else if let override = Self.environmentOverride(Self.appSupportDirectoryEnvKey, in: environment) {
            self.applicationSupportDirectory = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            let baseDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.applicationSupportDirectory = baseDirectory.appendingPathComponent("Kumo", isDirectory: true)
        }
        self.launchAgentsDirectory = launchAgentsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        if let override = Self.environmentOverride(Self.userAgentLabelEnvKey, in: environment),
           Self.isValidUserAgentLabel(override) {
            self.userAgentLabel = override
        } else {
            self.userAgentLabel = Self.userAgentLabel
        }
    }

    /// A user-agent label must stay a single launchd token: letters, digits,
    /// dot, hyphen or underscore. Slashes and whitespace are rejected so an
    /// environment override can never escape the plist directory or steer
    /// launchctl at another job.
    public static func isValidUserAgentLabel(_ label: String) -> Bool {
        guard !label.isEmpty else { return false }
        return label.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "." || character == "-" || character == "_")
        }
    }

    private static func environmentOverride(_ key: String, in environment: [String: String]) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    public var profilesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    public var workDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("work", isDirectory: true)
    }

    public var logsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public var overridesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("overrides", isDirectory: true)
    }

    public var overrideFilesDirectory: URL {
        overridesDirectory.appendingPathComponent("files", isDirectory: true)
    }

    public var subStoreDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("substore", isDirectory: true)
    }

    public var subStoreStatusFile: URL {
        subStoreDirectory.appendingPathComponent("status.json")
    }

    public var subStoreResourcesDirectory: URL {
        subStoreDirectory.appendingPathComponent("resources", isDirectory: true)
    }

    public var subStoreResourceManifestFile: URL {
        subStoreResourcesDirectory.appendingPathComponent("manifest.json")
    }

    public var subStoreNodeExecutable: URL {
        subStoreResourcesDirectory.appendingPathComponent("node/bin/node")
    }

    public var subStoreBackendBundle: URL {
        subStoreResourcesDirectory.appendingPathComponent("backend/sub-store.bundle.js")
    }

    public var subStoreDataDirectory: URL {
        subStoreDirectory.appendingPathComponent("data", isDirectory: true)
    }

    public var subStoreTempDirectory: URL {
        subStoreDirectory.appendingPathComponent("temp", isDirectory: true)
    }

    public var appUpdatesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("updates", isDirectory: true)
    }

    public var appUpdateDownloadsDirectory: URL {
        appUpdatesDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    public var appUpdateInstallerLogFile: URL {
        logsDirectory.appendingPathComponent("app-update-installer.log")
    }

    public var managedCoreDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("cores", isDirectory: true)
    }

    public var managedCoreExecutable: URL {
        managedCoreDirectory.appendingPathComponent("mihomo")
    }

    public var stateFile: URL {
        applicationSupportDirectory.appendingPathComponent("state.json")
    }

    public var agentSkillsStateFile: URL {
        applicationSupportDirectory.appendingPathComponent("agent-skills-state.json")
    }

    public var runtimeConfigFile: URL {
        workDirectory.appendingPathComponent("config.yaml")
    }

    public var corePIDFile: URL {
        workDirectory.appendingPathComponent("core.pid")
    }

    public var coreLogFile: URL {
        logsDirectory.appendingPathComponent("core.log")
    }

    public var runtimeEventsFile: URL {
        logsDirectory.appendingPathComponent("runtime-events.jsonl")
    }

    public var serviceSocketFile: URL {
        applicationSupportDirectory.appendingPathComponent("kumo-service.sock")
    }

    public var serviceStatusFile: URL {
        applicationSupportDirectory.appendingPathComponent("service-status.json")
    }

    public var serviceCredentialsFile: URL {
        applicationSupportDirectory.appendingPathComponent("service-credentials.json")
    }

    public var serviceLogFile: URL {
        logsDirectory.appendingPathComponent("kumo-service.log")
    }

    public var serviceExecutableFile: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools/io.kumo.KumoService")
    }

    public var serviceLaunchDaemonPlistFile: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons/io.kumo.KumoService.plist")
    }

    /// User-level LaunchAgent tier ("kumod"). Same app-support tree shape as
    /// the root daemon, but its own socket, log and LaunchAgents plist. A dev
    /// instance's overridden label yields a disjoint plist file name.
    public var userAgentPlistFile: URL {
        launchAgentsDirectory.appendingPathComponent("\(userAgentLabel).plist")
    }

    public var userAgentSocketFile: URL {
        applicationSupportDirectory.appendingPathComponent("kumo-agent.sock")
    }

    public var userAgentLogFile: URL {
        logsDirectory.appendingPathComponent("agent.log")
    }

    public var subStoreLogFile: URL {
        logsDirectory.appendingPathComponent("substore.log")
    }

    public var overridesMetadataFile: URL {
        overridesDirectory.appendingPathComponent("overrides.json")
    }

    public var proxyGeoCacheFile: URL {
        applicationSupportDirectory.appendingPathComponent("proxy-geo-cache.json")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profilesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: overridesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: overrideFilesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: subStoreDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: subStoreDataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: subStoreTempDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: appUpdatesDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: appUpdateDownloadsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedCoreDirectory,
            withIntermediateDirectories: true
        )
    }
}
