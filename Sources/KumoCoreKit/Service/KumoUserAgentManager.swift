import Darwin
import Foundation
import ServiceManagement

/// Manages the user-level LaunchAgent tier (`io.kumo.KumoAgent`, "kumod").
///
/// The agent is the unprivileged tier that owns the Mihomo core so the GUI
/// can quit while the core keeps running. It speaks the same signed Unix
/// socket protocol as the root daemon and reuses the same credentials file;
/// only the socket path (`kumo-agent.sock`), the log path and the launchd
/// domain (`gui/<uid>`) differ.
///
/// The agent is not permanently resident. The generated plist declares a
/// launchd `Sockets` listener (`launch_activate_socket` in the agent) with
/// `RunAtLoad=false` / `KeepAlive=false`, so launchd holds the endpoint and
/// starts the process on the first client connection. The agent then exits
/// on its own after `idleTimeoutSeconds` without traffic and with no core
/// running; see `ServiceIdlePolicy`.
public struct KumoUserAgentManager: Sendable {
    /// launchd `Sockets` entry name the agent adopts with
    /// `launch_activate_socket("Listener", ...)`.
    public static let launchdListenerSocketName = "Listener"
    /// `SockPathMode` for the launchd-created socket: 0600.
    public static let launchdSocketMode = Int(0o600)

    /// Ownership verdict for the pid recorded in the shared state, from the
    /// install guard's `kill(pid, 0)` probe.
    enum ProcessOwnership: Equatable, Sendable {
        /// The pid exists and this process may signal it (same uid, or root).
        case sameUser
        /// The pid exists but belongs to another uid (EPERM): provably the
        /// root daemon's core.
        case otherUser
        /// No such process (ESRCH) or any other inconclusive outcome.
        case unknown
    }

    /// Idle window the generated plist passes to `service run --idle-timeout`.
    public let idleTimeoutSeconds: Int
    private let paths: KumoPaths
    /// Bundle whose embedded LaunchAgent decides the install path. `nil`
    /// means `Bundle.main`.
    private let bundleURL: URL?
    /// launchctl execution seam for tests. `nil` runs `/bin/launchctl`.
    private let launchctlRunner: (@Sendable ([String]) throws -> String)?
    /// Root-daemon reachability seam for the install guard. `nil` uses the
    /// live signed-socket status.
    private let rootDaemonReachability: (@Sendable () -> Bool)?
    /// Process-ownership seam for the install guard. `nil` uses
    /// `kill(pid, 0)`.
    private let processOwnershipProbe: (@Sendable (Int32) -> ProcessOwnership)?

    public init(
        paths: KumoPaths = KumoPaths(),
        idleTimeoutSeconds: Int = ServiceIdlePolicy.defaultTimeoutSeconds
    ) {
        self.init(
            paths: paths,
            idleTimeoutSeconds: idleTimeoutSeconds,
            bundleURL: nil,
            launchctlRunner: nil,
            rootDaemonReachability: nil,
            processOwnershipProbe: nil
        )
    }

    /// Test seam: injects the app bundle, the launchctl runner and the
    /// root-owned-core install-guard probes so the bundled-plist decision, the
    /// generated-plist fallback and the refusal decision can be exercised
    /// without the real bundle, a real launchd domain or a real root daemon.
    init(
        paths: KumoPaths,
        idleTimeoutSeconds: Int = ServiceIdlePolicy.defaultTimeoutSeconds,
        bundleURL: URL?,
        launchctlRunner: (@Sendable ([String]) throws -> String)? = nil,
        rootDaemonReachability: (@Sendable () -> Bool)? = nil,
        processOwnershipProbe: (@Sendable (Int32) -> ProcessOwnership)? = nil
    ) {
        self.paths = paths
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.bundleURL = bundleURL
        self.launchctlRunner = launchctlRunner
        self.rootDaemonReachability = rootDaemonReachability
        self.processOwnershipProbe = processOwnershipProbe
    }

    /// Effective launchd label, honored by plist generation and launchctl.
    public var launchAgentLabel: String {
        paths.userAgentLabel
    }

    /// Effective plist file name, derived from the effective label.
    public var launchAgentPlistName: String {
        "\(paths.userAgentLabel).plist"
    }

    /// Whether the agent tier is installed: a LaunchAgents plist or a
    /// registered bundled `SMAppService` job. Unlike `status()`, this performs
    /// no socket ping, which matters to callers that must not activate the
    /// on-demand agent (launchd starts it on the first connection).
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.userAgentPlistFile.path)
            || isBundledAgentRegistered
    }

    /// Version marker written after a successful agent install; compared with
    /// the running app version on launch to decide whether the LaunchAgent
    /// job (plist paths and shape) needs to be rewritten.
    var installVersionStampFile: URL {
        paths.applicationSupportDirectory.appendingPathComponent("agent-version.json")
    }

    /// App version recorded when the agent was last installed; `nil` when it
    /// was never stamped (an install from before version tracking).
    func recordedInstallVersion() -> String? {
        KumoInstallVersionStamp.read(from: installVersionStampFile)
    }

    public func status() -> ServiceModeStatus {
        let installed = isInstalled
        let running = client()?.ping() == true

        return ServiceModeStatus(
            isInstalled: installed,
            isRunning: running,
            isAvailable: running,
            isCurrentProcessPrivileged: geteuid() == 0,
            socketPath: paths.userAgentSocketFile.path,
            message: statusMessage(isInstalled: installed, isRunning: running)
        )
    }

    /// Installs (or repairs) the user agent, reusing the shared credentials
    /// file the root tier uses. Inside a bundled app the agent is registered
    /// through `SMAppService.agent`, but only when the bundled plist's
    /// absolute paths are valid for this machine. Otherwise — the bundle was
    /// built or moved on another machine — a generated plist with
    /// machine-correct paths is bootstrapped into the caller's `gui` domain,
    /// as it always is for source-tree and dev runs.
    @discardableResult
    public func install() throws -> ServiceModeStatus {
        try install(executable: nil)
    }

    /// Installs (or repairs) the agent and records `appVersion` in the
    /// install-time stamp. `nil` falls back to the running bundle's version,
    /// and when neither is available (bare-executable callers) the stamp is
    /// left untouched.
    @discardableResult
    public func install(executable: URL?, appVersion: String? = nil) throws -> ServiceModeStatus {
        if let refusal = rootOwnedCoreInstallRefusal() {
            throw refusal
        }

        _ = try ensureCredentials()
        try paths.prepare()

        let installed: ServiceModeStatus
        if isBundledApp,
           Self.bundledPlistIsValidForCurrentMachine(bundleURL: resolvedBundleURL, paths: paths),
           registerBundledAgentIfPossible() {
            installed = status()
        } else {
            let executableURL = try executable ?? serviceExecutableCandidate()
            try writeLaunchAgentPlist(executable: executableURL)
            try reloadAgent()
            installed = status()
        }

        // Best effort: a failed stamp write only means the next launch
        // repairs once more, which is safe because install() is idempotent.
        if let version = appVersion ?? KumoInstallVersionStamp.currentAppVersion() {
            try? KumoInstallVersionStamp.write(version: version, to: installVersionStampFile)
        }
        return installed
    }

    /// Re-runs the idempotent install when the version recorded at install
    /// time differs from `currentVersion`. A missing stamp counts as
    /// different: installs from before version stamping cannot be verified,
    /// so the first launch repairs once and records the running version.
    /// Returns the refreshed status when a repair ran, `nil` when no agent is
    /// installed or it is already current.
    @discardableResult
    public func repairInstallIfVersionChanged(
        currentVersion: String,
        executable: URL? = nil
    ) throws -> ServiceModeStatus? {
        guard isInstalled else { return nil }
        guard recordedInstallVersion() != currentVersion else { return nil }
        return try install(executable: executable, appVersion: currentVersion)
    }

    @discardableResult
    public func uninstall() throws -> ServiceModeStatus {
        if isBundledApp {
            try? SMAppService.agent(plistName: launchAgentPlistName).unregister()
        }
        _ = try? runLaunchctl(["bootout", "\(launchdDomain)/\(launchAgentLabel)"])
        try? FileManager.default.removeItem(at: paths.userAgentPlistFile)
        // bootout unregisters the job, but this host's launchd does not unlink
        // a SockPathName socket on bootout (and a self-bound dev run leaves
        // its own file behind), so remove the endpoint explicitly.
        try? FileManager.default.removeItem(at: paths.userAgentSocketFile)
        // Drop the install-time marker with the job it describes.
        try? FileManager.default.removeItem(at: installVersionStampFile)
        return status()
    }

    public func client() -> KumoServiceClient? {
        KumoServiceManager(paths: paths).serviceClient(socketPath: paths.userAgentSocketFile.path)
    }

    public func ensureCredentials() throws -> KumoServiceCredentials {
        try KumoServiceManager(paths: paths).ensureCredentials()
    }

    public func loadCredentials() throws -> KumoServiceCredentials {
        try KumoServiceManager(paths: paths).loadCredentials()
    }

    // MARK: - LaunchAgent management

    /// The generated user-agent plist. On-demand activation: launchd creates
    /// the socket itself (`Sockets` → `SockPathName`) and starts the agent on
    /// the first connection, so neither `RunAtLoad` nor `KeepAlive` is set.
    /// The agent exits again after its idle timeout.
    ///
    /// A dev instance's overridden label is carried into the job's
    /// `EnvironmentVariables` so the launchd-started process resolves the same
    /// label. The default label emits no environment block, keeping the
    /// production plist byte-identical.
    public static func launchAgentPlist(
        executable: URL,
        paths: KumoPaths,
        idleTimeoutSeconds: Int = ServiceIdlePolicy.defaultTimeoutSeconds
    ) -> String {
        let environmentVariables = paths.userAgentLabel == KumoPaths.userAgentLabel
            ? ""
            : "<key>EnvironmentVariables</key>\n"
                + "<dict>\n"
                + "  <key>\(KumoPaths.userAgentLabelEnvKey)</key>\n"
                + "  <string>\(paths.userAgentLabel)</string>\n"
                + "</dict>\n"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(paths.userAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(executable.path)</string>
            <string>service</string>
            <string>run</string>
            <string>--mode</string>
            <string>user</string>
            <string>--app-support</string>
            <string>\(paths.applicationSupportDirectory.path)</string>
            <string>--idle-timeout</string>
            <string>\(idleTimeoutSeconds)</string>
          </array>
        \(environmentVariables)  <key>Sockets</key>
          <dict>
            <key>\(Self.launchdListenerSocketName)</key>
            <dict>
              <key>SockPathName</key>
              <string>\(paths.userAgentSocketFile.path)</string>
              <key>SockPathMode</key>
              <integer>\(Self.launchdSocketMode)</integer>
            </dict>
          </dict>
          <key>RunAtLoad</key>
          <false/>
          <key>KeepAlive</key>
          <false/>
          <key>StandardOutPath</key>
          <string>\(paths.userAgentLogFile.path)</string>
          <key>StandardErrorPath</key>
          <string>\(paths.userAgentLogFile.path)</string>
        </dict>
        </plist>
        """
    }

    private func writeLaunchAgentPlist(executable: URL) throws {
        try FileManager.default.createDirectory(
            at: paths.launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try Self.launchAgentPlist(
            executable: executable,
            paths: paths,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
        .write(to: paths.userAgentPlistFile, atomically: true, encoding: .utf8)
    }

    private func reloadAgent() throws {
        _ = try? runLaunchctl(["bootout", "\(launchdDomain)/\(launchAgentLabel)"])
        try runLaunchctl(["bootstrap", launchdDomain, paths.userAgentPlistFile.path])
        // No kickstart: the `Sockets` listener owns the endpoint, so a later
        // client connection starts the agent on demand. Some macOS versions
        // start the job once at bootstrap even with RunAtLoad=false; either
        // way the idle timeout bounds how long that run stays resident.
    }

    /// True when the bundled agent plist can serve this machine, so
    /// `install()` may use `SMAppService.agent`. Otherwise the generated
    /// plist fallback writes machine-correct paths.
    ///
    /// The plist at `Contents/Library/LaunchAgents` is rendered at build time
    /// with absolute paths, and `SMAppService` registration does not verify
    /// them. A `Kumo.app` built or moved on another machine would otherwise
    /// register a job whose helper or `--app-support` path belongs to
    /// someone else — and registration would succeed, so the fallback would
    /// never run. The check therefore requires the recorded executable to
    /// exist and be executable, and the `--app-support` value to be the
    /// current user's app-support directory.
    static func bundledPlistIsValidForCurrentMachine(bundleURL: URL, paths: KumoPaths) -> Bool {
        let plistURL = bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(paths.userAgentLabel).plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let arguments = object["ProgramArguments"] as? [String],
              let executablePath = arguments.first,
              FileManager.default.isExecutableFile(atPath: executablePath),
              let appSupportIndex = arguments.firstIndex(of: "--app-support"),
              arguments.indices.contains(arguments.index(after: appSupportIndex))
        else {
            return false
        }
        return arguments[arguments.index(after: appSupportIndex)]
            == paths.applicationSupportDirectory.path
    }

    /// Returns true when the registered agent service was enabled. A missing
    /// embedded plist (packaging not final yet) or a ServiceManagement refusal
    /// falls through to the launchctl fallback.
    private func registerBundledAgentIfPossible() -> Bool {
        let service = SMAppService.agent(plistName: launchAgentPlistName)
        if service.status == .enabled {
            try? service.unregister()
        }
        do {
            try service.register()
            return true
        } catch {
            return false
        }
    }

    private var isBundledAgentRegistered: Bool {
        guard isBundledApp else { return false }
        return SMAppService.agent(plistName: launchAgentPlistName).status == .enabled
    }

    private var resolvedBundleURL: URL {
        bundleURL ?? Bundle.main.bundleURL
    }

    private var isBundledApp: Bool {
        resolvedBundleURL.pathExtension == "app"
    }

    private var launchdDomain: String {
        "gui/\(getuid())"
    }

    private func serviceExecutableCandidate() throws -> URL {
        let candidates = KumoServiceManager.helperExecutableCandidates(
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            installedHelperURL: paths.serviceExecutableFile
        )

        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }

        throw KumoError.serviceUnavailable(
            "KumoService executable was not found. Build or bundle KumoService before installing the user agent."
        )
    }

    /// Refuses to install the agent on top of a core that the root daemon
    /// provably owns while TUN is enabled.
    ///
    /// Installing the agent while the root daemon runs the core used to strand
    /// that core: routing then prefers the agent, but the agent cannot signal
    /// the root-owned pid (EPERM) and `migrateCoreToUserAgent()` read the
    /// routing decision as agent ownership and silently no-opped. The
    /// ownership record fixes the migration, so the guard now fires only when
    /// TUN pins the core to the root daemon and the core cannot be handed
    /// over at all (`kumo agent migrate` refuses while TUN is on).
    ///
    /// Ownership is consulted from the record first (`CoreStatus.ownerTier`);
    /// only a legacy state without one falls back to the process probe. A
    /// non-root record proves the core is not root-owned, so the install is
    /// allowed regardless of what the probe would report.
    ///
    /// With TUN off, the install is the first step of the recovery: it is
    /// allowed, and the proven root ownership is stamped into the state so the
    /// follow-up `kumo agent migrate` reads the record instead of the routing
    /// decision, which now prefers the just-installed agent.
    ///
    /// The guard fires only when the conditions are provable: the root daemon
    /// is reachable, the shared state reports a running core with a pid,
    /// ownership resolves to the root daemon, and TUN is enabled. Every
    /// ambiguous state — no state file, unreadable state, no running core,
    /// missing or stale pid, unreachable daemon — allows the install.
    private func rootOwnedCoreInstallRefusal() -> KumoError? {
        let daemonReachable = rootDaemonReachability?()
            ?? KumoServiceManager(paths: paths).status().isRunning
        guard daemonReachable else { return nil }

        let stateStore = CoreStateStore(paths: paths)
        guard let status = try? stateStore.load(),
              status.state == .running,
              let pid = status.pid else {
            return nil
        }

        let provenByRecord: Bool
        if let owner = status.ownerTier, owner != .unknown {
            // The record is authoritative; the probe is only a legacy fallback.
            guard owner == .rootService else { return nil }
            provenByRecord = true
        } else {
            let ownership = processOwnershipProbe?(pid) ?? Self.processOwnership(of: pid)
            guard ownership == .otherUser else { return nil }
            provenByRecord = false
        }

        let tunEnabled = status.runtimeSettings?.tun?.isEnabled ?? false
        if !tunEnabled {
            if !provenByRecord {
                // Record what the probe just proved so the migration can find
                // it. Best-effort: a denied write must not block the install.
                var recorded = status
                recorded.ownerTier = .rootService
                try? stateStore.save(recorded)
            }
            return nil
        }

        return KumoError.serviceUnavailable(
            "TUN is enabled, so Kumo Helper must keep the running Mihomo core while TUN is active. Disable TUN, then retry installing the agent, then run `kumo agent migrate` to hand the core over."
        )
    }

    private static func processOwnership(of pid: Int32) -> ProcessOwnership {
        guard kill(pid, 0) != 0 else { return .sameUser }
        return errno == EPERM ? .otherUser : .unknown
    }

    private func statusMessage(isInstalled: Bool, isRunning: Bool) -> String? {
        if isRunning {
            return "Kumo agent is running on demand. The core keeps running when the app quits."
        }
        if isInstalled {
            return "Kumo agent is installed. It starts on demand when a client connects."
        }
        return "The user-level Kumo agent is not installed."
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) throws -> String {
        if let launchctlRunner {
            return try launchctlRunner(arguments)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw KumoError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
