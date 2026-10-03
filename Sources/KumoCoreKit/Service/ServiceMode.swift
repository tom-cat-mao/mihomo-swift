import Foundation

/// Runtime tier of a `KumoService` process.
///
/// The root tier is the administrator-authorized LaunchDaemon
/// (`io.kumo.KumoService`) that owns privileged networking (TUN, system
/// proxy). The user tier is the unprivileged LaunchAgent
/// (`io.kumo.KumoAgent`, "kumod") that owns the Mihomo core so the GUI can
/// quit while the core keeps running. Both speak the same signed Unix socket
/// protocol and share the credentials file; only the socket path, log path
/// and launchd domain differ.
public enum ServiceMode: String, CaseIterable, Sendable {
    case root
    case user

    public static let defaultMode: ServiceMode = .root

    /// Parses `--mode root|user` from `service` subcommand arguments.
    /// Absent flag means root, preserving the original daemon behavior.
    public static func parse(arguments: [String]) throws -> ServiceMode {
        guard let rawValue = value(after: "--mode", in: arguments) else {
            return .root
        }
        guard let mode = ServiceMode(rawValue: rawValue) else {
            throw KumoError.invalidArguments("Unknown service mode: \(rawValue). Use root or user.")
        }
        return mode
    }

    /// The root daemon refuses install/uninstall without administrator
    /// privileges; the user agent runs as its owner.
    public var requiresRoot: Bool {
        self == .root
    }

    /// Root chowns the socket and credentials to the authorized uid. The
    /// user agent's files are already owned by the authorized user.
    public var chownsSharedFilesToAuthorizedUID: Bool {
        self == .root
    }

    /// Root writes app-support files as root and hands them back with
    /// `AppSupportOwnershipRepair`; the user agent owns them already.
    public var repairsAppSupportOwnership: Bool {
        self == .root
    }

    /// Root records lifecycle state in the shared `service-status.json`.
    /// The user agent leaves that file to the root tier so the two tiers do
    /// not overwrite each other's install state.
    public var writesSharedStatusFile: Bool {
        self == .root
    }

    public var launchdLabel: String {
        switch self {
        case .root: KumoServiceManager.launchDaemonLabel
        case .user: KumoPaths.userAgentLabel
        }
    }

    /// Socket clients and the server bind per tier: `kumo-service.sock` for
    /// root, `kumo-agent.sock` for the user agent.
    public func socketFile(in paths: KumoPaths) -> URL {
        switch self {
        case .root: paths.serviceSocketFile
        case .user: paths.userAgentSocketFile
        }
    }

    public func logFile(in paths: KumoPaths) -> URL {
        switch self {
        case .root: paths.serviceLogFile
        case .user: paths.userAgentLogFile
        }
    }

    public func launchdPlistFile(in paths: KumoPaths) -> URL {
        switch self {
        case .root: paths.serviceLaunchDaemonPlistFile
        case .user: paths.userAgentPlistFile
        }
    }

    /// Message served by `GET /service/status` on this tier.
    public var serviceStatusMessage: String {
        switch self {
        case .root: "Kumo Helper is running."
        case .user: "Kumo agent is running."
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}
