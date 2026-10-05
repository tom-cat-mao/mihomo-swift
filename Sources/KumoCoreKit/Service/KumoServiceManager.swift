import Darwin
import Foundation

/// Version marker both tiers write at install time, so the app can tell
/// whether the helper or agent on disk was installed by the version now
/// running. After an in-app update the installed copies still belong to the
/// previous bundle, and nothing else would re-validate them.
struct KumoInstallVersionStamp: Codable, Equatable, Sendable {
    var version: String

    static func read(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let stamp = try? JSONDecoder().decode(KumoInstallVersionStamp.self, from: data),
              !stamp.version.isEmpty else {
            return nil
        }
        return stamp.version
    }

    static func write(version: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(KumoInstallVersionStamp(version: version)).write(to: url, options: .atomic)
    }

    /// The running bundle's `CFBundleShortVersionString` — the same version
    /// the update check and About window report. `nil` for bare executables
    /// (CLI and helpers outside an app bundle); callers then skip stamping and
    /// the app treats the install as unverifiable.
    static func currentAppVersion() -> String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return nil
        }
        return version
    }
}

/// Version relationship between the running app and the privileged helper
/// copy at `/Library/PrivilegedHelperTools/io.kumo.KumoService`.
public enum HelperVersionVerdict: Equatable, Sendable {
    /// No helper install markers were found; nothing to refresh.
    case notInstalled
    /// The version recorded at install time matches the running app.
    case current
    /// A helper is installed, but its recorded version differs — or was never
    /// recorded, for installs that predate version stamping. Detection only:
    /// the user triggers the repair through Install / Repair Service, which
    /// performs the administrator authorization. Nothing elevates on launch.
    case stale(installedVersion: String?)

    /// Prompt surfaced through the service-mode status message.
    public var repairMessage: String? {
        guard case .stale = self else { return nil }
        return "Kumo Helper may be out of date. Use Install / Repair Service to update it."
    }
}

public struct KumoServiceManager: Sendable {
    public static let launchDaemonLabel = "io.kumo.KumoService"

    private let paths: KumoPaths
    /// Test seam: replaces the privileged service-command execution (including
    /// helper-executable resolution) so uninstall bookkeeping can be exercised
    /// without osascript authorization or an installed helper. `nil` runs the
    /// real command.
    private let serviceCommandRunner: (@Sendable ([String], String) throws -> Void)?
    /// Test seam for the install-state probe: the LaunchDaemon path and helper
    /// are fixed `/Library` locations, so a test on a machine with a real
    /// helper needs to pin the verdict instead of reading production state.
    /// `nil` probes the live locations.
    private let isInstalledOverride: Bool?

    public init(paths: KumoPaths = KumoPaths()) {
        self.init(paths: paths, serviceCommandRunner: nil)
    }

    init(
        paths: KumoPaths,
        serviceCommandRunner: (@Sendable ([String], String) throws -> Void)? = nil,
        isInstalledOverride: Bool? = nil
    ) {
        self.paths = paths
        self.serviceCommandRunner = serviceCommandRunner
        self.isInstalledOverride = isInstalledOverride
    }

    /// Whether the privileged helper is installed: LaunchDaemon plist,
    /// installed executable or the saved install flag. Ping-free on purpose —
    /// callers that must not wake the service (and the launch-time version
    /// check) only need the on-disk install state.
    var isInstalled: Bool {
        if let isInstalledOverride {
            return isInstalledOverride
        }
        return FileManager.default.fileExists(atPath: paths.serviceLaunchDaemonPlistFile.path)
            || FileManager.default.fileExists(atPath: paths.serviceExecutableFile.path)
            || savedInstalledFlag()
    }

    /// Version marker written after a successful helper install. Lives next to
    /// the shared service bookkeeping because the privileged helper location
    /// itself is not writable by the app.
    var helperVersionStampFile: URL {
        paths.applicationSupportDirectory.appendingPathComponent("service-version.json")
    }

    /// App version recorded when the helper was last installed; `nil` when it
    /// was never stamped (an install from before version tracking).
    func recordedHelperVersion() -> String? {
        KumoInstallVersionStamp.read(from: helperVersionStampFile)
    }

    /// Compares the version recorded at helper install time with the running
    /// app. A missing stamp counts as stale: an install that predates
    /// stamping cannot be verified, and re-running the existing Install /
    /// Repair path once records one.
    public func helperVersionVerdict(currentVersion: String) -> HelperVersionVerdict {
        guard isInstalled else { return .notInstalled }
        guard let recorded = recordedHelperVersion() else {
            return .stale(installedVersion: nil)
        }
        return recorded == currentVersion ? .current : .stale(installedVersion: recorded)
    }

    public func status() -> ServiceModeStatus {
        let isPrivileged = geteuid() == 0
        let socketPath = paths.serviceSocketFile.path
        let socketExists = FileManager.default.fileExists(atPath: socketPath)
        let installed = isInstalled
        let running = isPrivileged ? socketExists : serviceClient()?.ping() == true
        let available = running || isPrivileged

        return ServiceModeStatus(
            isInstalled: installed,
            isRunning: running,
            isAvailable: available,
            isCurrentProcessPrivileged: isPrivileged,
            socketPath: socketPath,
            message: statusMessage(isInstalled: installed, isRunning: running, isPrivileged: isPrivileged)
        )
    }

    @discardableResult
    public func installService(appVersion: String? = nil) throws -> ServiceModeStatus {
        let credentials = try ensureCredentials()
        // With an injected runner the privileged command never runs, so the
        // source path is bookkeeping only and executable resolution is
        // skipped (tests have no helper binary to resolve).
        let source = serviceCommandRunner == nil
            ? try helperExecutableCandidate()
            : paths.serviceExecutableFile
        let arguments = [
            "service",
            "install",
            "--source", source.path,
            "--app-support", paths.applicationSupportDirectory.path,
            "--authorized-uid", "\(getuid())",
            "--key-id", credentials.keyID,
            "--shared-secret", credentials.sharedSecret
        ]
        if let serviceCommandRunner {
            try serviceCommandRunner(arguments, "Install Kumo Helper")
        } else {
            try runServiceCommandWithAuthorization(
                executable: source.path,
                arguments: arguments,
                prompt: "Install Kumo Helper"
            )
        }
        // Best effort: if the stamp cannot be written the launch check simply
        // prompts a repair once more, which is idempotent.
        if let version = appVersion ?? KumoInstallVersionStamp.currentAppVersion() {
            try? KumoInstallVersionStamp.write(version: version, to: helperVersionStampFile)
        }
        let status = status()
        try saveInstalledFlag(status)
        return status
    }

    @discardableResult
    public func uninstallService() throws -> ServiceModeStatus {
        try runServiceCommand(
            ["service", "uninstall", "--app-support", paths.applicationSupportDirectory.path],
            prompt: "Uninstall Kumo Helper"
        )
        // Drop the install-time marker with the helper it describes.
        try? FileManager.default.removeItem(at: helperVersionStampFile)
        // The user agent (kumod) reuses this shared credentials file. Deleting
        // it while the agent is installed would make every agent start fail at
        // credential load, silently killing keep-core-alive. The check is
        // ping-free on purpose: `status()` pings the on-demand agent endpoint,
        // and connecting would start the agent through launchd as a side
        // effect. Plain plist presence alone is not enough either — a bundled
        // agent registered through `SMAppService` has no LaunchAgents copy.
        if !KumoUserAgentManager(paths: paths).isInstalled {
            try? FileManager.default.removeItem(at: paths.serviceCredentialsFile)
        }
        let next = status()
        try saveInstalledFlag(next)
        return next
    }

    public func serviceClient() -> KumoServiceClient? {
        serviceClient(socketPath: paths.serviceSocketFile.path)
    }

    /// Builds a signed client for an arbitrary socket while reusing the shared
    /// credentials file. The user-agent tier targets `userAgentSocketFile`.
    public func serviceClient(socketPath: String) -> KumoServiceClient? {
        guard let credentials = try? loadCredentials() else {
            return nil
        }
        return KumoServiceClient(
            endpoint: KumoServiceEndpoint(socketPath: socketPath),
            credentials: credentials
        )
    }

    public func ensureCredentials() throws -> KumoServiceCredentials {
        if let credentials = try? loadCredentials() {
            return credentials
        }
        let credentials = KumoServiceCredentials(
            keyID: UUID().uuidString,
            sharedSecret: UUID().uuidString + UUID().uuidString
        )
        try FileManager.default.createDirectory(
            at: paths.serviceCredentialsFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(credentials).write(to: paths.serviceCredentialsFile, options: .atomic)
        chmod(paths.serviceCredentialsFile.path, S_IRUSR | S_IWUSR)
        return credentials
    }

    public func loadCredentials() throws -> KumoServiceCredentials {
        let data = try Data(contentsOf: paths.serviceCredentialsFile)
        return try JSONDecoder().decode(KumoServiceCredentials.self, from: data)
    }

    private func savedInstalledFlag() -> Bool {
        guard let data = try? Data(contentsOf: paths.serviceStatusFile),
              let object = try? JSONDecoder().decode(ServiceModeStatus.self, from: data) else {
            return false
        }
        return object.isInstalled
    }

    private func saveInstalledFlag(_ status: ServiceModeStatus) throws {
        try FileManager.default.createDirectory(
            at: paths.serviceStatusFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: paths.serviceStatusFile, options: .atomic)
    }

    private func statusMessage(isInstalled: Bool, isRunning: Bool, isPrivileged: Bool) -> String? {
        if isRunning {
            return "Kumo Helper is running. System proxy service mode and TUN can use the privileged backend."
        }
        if isPrivileged {
            return "Current process is privileged. TUN can run without the helper, but installing Kumo Helper is recommended."
        }
        if isInstalled {
            return "Kumo Helper is installed but not reachable. Use Install / Repair Service to reload it."
        }
        return "TUN requires Kumo Helper or a privileged Kumo process. Installing the helper shows a macOS administrator authorization prompt, not a VPN configuration prompt."
    }

    static func helperExecutableCandidates(
        bundleURL: URL,
        executableURL: URL?,
        workingDirectory: URL,
        installedHelperURL: URL
    ) -> [URL] {
        let executableDirectory = executableURL?.deletingLastPathComponent()
        let productDirectory = bundleURL.deletingLastPathComponent()
        return [
            bundleURL.appendingPathComponent("Contents/MacOS/KumoService"),
            bundleURL.appendingPathComponent("Contents/Helpers/KumoService"),
            executableDirectory?.deletingLastPathComponent().appendingPathComponent("MacOS/KumoService"),
            productDirectory.appendingPathComponent("KumoService"),
            executableDirectory?.appendingPathComponent("KumoService"),
            workingDirectory.appendingPathComponent("KumoService"),
            workingDirectory.appendingPathComponent(".build/debug/KumoService"),
            workingDirectory.appendingPathComponent(".build/release/KumoService"),
            workingDirectory.appendingPathComponent("build/Build/Products/Debug/KumoService"),
            workingDirectory.appendingPathComponent("build/Build/Products/Release/KumoService"),
            installedHelperURL
        ].compactMap { $0 }
    }

    private func helperExecutableCandidate() throws -> URL {
        let candidates = Self.helperExecutableCandidates(
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            installedHelperURL: paths.serviceExecutableFile
        )

        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }

        throw KumoError.serviceUnavailable(
            "KumoService executable was not found. Build or bundle KumoService before installing the helper."
        )
    }

    /// Runs a privileged service command, resolving the helper executable
    /// (installed helper first, then build/bundle candidates). The injected
    /// runner short-circuits resolution for tests.
    private func runServiceCommand(_ arguments: [String], prompt: String) throws {
        if let serviceCommandRunner {
            return try serviceCommandRunner(arguments, prompt)
        }
        let executable = FileManager.default.isExecutableFile(atPath: paths.serviceExecutableFile.path)
            ? paths.serviceExecutableFile
            : try helperExecutableCandidate()
        try runServiceCommandWithAuthorization(
            executable: executable.path,
            arguments: arguments,
            prompt: prompt
        )
    }

    private func runServiceCommandWithAuthorization(
        executable: String,
        arguments: [String],
        prompt: String
    ) throws {
        if geteuid() == 0 {
            try run(executable: executable, arguments: arguments)
            return
        }

        let command = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        let script = #"do shell script "\#(appleScriptQuote(command))" with administrator privileges with prompt "\#(appleScriptQuote(prompt))""#
        try run(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    private func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw KumoError.serviceUnavailable(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
