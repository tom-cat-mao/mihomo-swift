import Darwin
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

    fileprivate static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

extension ServiceMode {
    /// LaunchDaemon plist for the root tier. Owned here rather than by the
    /// `KumoService` executable so tests can pin its exact contents: the
    /// user-agent on-demand work must not change root-mode registration.
    public static func rootLaunchDaemonPlist(paths: KumoPaths, authorizedUID: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(KumoServiceManager.launchDaemonLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(paths.serviceExecutableFile.path)</string>
            <string>service</string>
            <string>run</string>
            <string>--app-support</string>
            <string>\(paths.applicationSupportDirectory.path)</string>
            <string>--authorized-uid</string>
            <string>\(authorizedUID)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\(paths.serviceLogFile.path)</string>
          <key>StandardErrorPath</key>
          <string>\(paths.serviceLogFile.path)</string>
        </dict>
        </plist>
        """
    }
}

/// Idle-exit policy for the user-level agent tier ("kumod").
///
/// `kumod` is not meant to be permanently resident: launchd starts it on
/// demand through socket activation and it exits once it has served no client
/// request for `timeout` seconds and owns no running Mihomo core. The root
/// daemon has no such policy and stays resident.
///
/// The policy is a value type with an injected clock so the exit decision is
/// testable without sleeping.
public struct ServiceIdlePolicy: Sendable {
    /// Default `--idle-timeout` for the user agent, in seconds.
    public static let defaultTimeoutSeconds = 300

    /// Seconds without a served client request before the agent may exit.
    public let timeout: TimeInterval
    /// Timestamp of the last served (or in-flight) client request.
    public private(set) var lastActivity: Date
    /// Requests currently being handled; an in-flight request always
    /// suppresses the idle exit.
    public private(set) var inFlightRequests: Int

    public init(timeout: TimeInterval = TimeInterval(Self.defaultTimeoutSeconds), now: Date) {
        self.timeout = timeout
        self.lastActivity = now
        self.inFlightRequests = 0
    }

    public mutating func requestStarted(at now: Date) {
        inFlightRequests += 1
        lastActivity = now
    }

    public mutating func requestFinished(at now: Date) {
        inFlightRequests = max(0, inFlightRequests - 1)
        lastActivity = now
    }

    /// The agent may exit only when it has served no request for `timeout`
    /// seconds, no request is in flight, and no Mihomo core is running.
    public func shouldExit(now: Date, isCoreRunning: Bool) -> Bool {
        guard timeout > 0, !isCoreRunning, inFlightRequests == 0 else {
            return false
        }
        return now.timeIntervalSince(lastActivity) >= timeout
    }

    /// How long the socket loop may block in `poll` before re-evaluating the
    /// policy. Ticks are capped at `maximum` seconds — and stay pinned there
    /// while a core is running, because an exit is impossible until that core
    /// stops.
    public func nextCheckIntervalSeconds(
        at now: Date,
        isCoreRunning: Bool,
        maximum: TimeInterval = 5
    ) -> TimeInterval {
        guard !isCoreRunning else { return maximum }
        let remaining = lastActivity.addingTimeInterval(timeout).timeIntervalSince(now)
        return max(0.1, min(remaining, maximum))
    }

    /// Parses `--idle-timeout <seconds>` from `service run` arguments,
    /// defaulting to `defaultTimeoutSeconds` when the flag is absent. The
    /// value must be a positive integer number of seconds.
    public static func parseTimeoutSeconds(arguments: [String]) throws -> Int {
        guard let rawValue = ServiceMode.value(after: "--idle-timeout", in: arguments) else {
            guard !arguments.contains("--idle-timeout") else {
                throw KumoError.invalidArguments("--idle-timeout requires a value in seconds.")
            }
            return defaultTimeoutSeconds
        }
        guard let seconds = Int(rawValue), seconds > 0 else {
            throw KumoError.invalidArguments(
                "Invalid --idle-timeout value: \(rawValue). Use a positive number of seconds."
            )
        }
        return seconds
    }
}
