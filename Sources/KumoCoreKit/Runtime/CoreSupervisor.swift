import Darwin
import Foundation
import os

/// Runtime-event rows are diagnostics, not control state.
private let supervisorLogger = Logger(subsystem: "io.kumo.KumoApp", category: "supervisor")

public struct CoreLaunchConfiguration: Sendable {
    public var corePath: String?
    public var profile: Profile
    public var overrideYAMLs: [String]
    public var endpoint: ControllerEndpoint
    public var proxyPorts: ProxyPortConfiguration
    public var mode: OutboundMode
    public var runtimeSettings: CoreRuntimeSettings

    public init(
        corePath: String? = nil,
        profile: Profile,
        overrideYAMLs: [String] = [],
        endpoint: ControllerEndpoint = ControllerEndpoint(),
        proxyPorts: ProxyPortConfiguration = ProxyPortConfiguration(),
        mode: OutboundMode = .rule,
        runtimeSettings: CoreRuntimeSettings = CoreRuntimeSettings()
    ) {
        self.corePath = corePath
        self.profile = profile
        self.overrideYAMLs = overrideYAMLs
        self.endpoint = endpoint
        self.proxyPorts = proxyPorts
        self.mode = mode
        self.runtimeSettings = runtimeSettings
    }
}

struct CoreRecoveryPolicy: Sendable {
    var backoffs: [TimeInterval]
    var stableInterval: TimeInterval

    static let `default` = CoreRecoveryPolicy(backoffs: [2, 5, 15], stableInterval: 300)

    static func testing(backoffs: [TimeInterval] = [0.05, 0.05, 0.05], stableInterval: TimeInterval = 300) -> CoreRecoveryPolicy {
        CoreRecoveryPolicy(backoffs: backoffs, stableInterval: stableInterval)
    }
}

private struct SupervisedLaunch {
    let id: UUID
    let process: Process
    let configuration: CoreLaunchConfiguration
    let launchedAt: Date
    var expectedStop = false
}

/// Process objects cannot be shared across processes, but they must be shared
/// by the short-lived controller values created for each agent/daemon request.
/// The registry is process-local and keyed by the app-support root.
private final class CoreSupervisionRegistry: @unchecked Sendable {
    static let shared = CoreSupervisionRegistry()

    private let lock = NSLock()
    private var sessions: [String: CoreSupervisionSession] = [:]

    func session(for paths: KumoPaths) -> CoreSupervisionSession {
        let key = paths.applicationSupportDirectory.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] {
            return session
        }
        let session = CoreSupervisionSession()
        sessions[key] = session
        return session
    }
}

private final class CoreSupervisionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SupervisedLaunch?
    private var handledLaunchIDs: [UUID] = []
    private var recoveryAttempt = 0
    private var recoveryToken = UUID()

    func attach(process: Process, configuration: CoreLaunchConfiguration, launchedAt: Date) -> UUID {
        let launch = SupervisedLaunch(
            id: UUID(),
            process: process,
            configuration: configuration,
            launchedAt: launchedAt
        )
        lock.lock()
        current = launch
        lock.unlock()
        return launch.id
    }

    func currentLaunch() -> SupervisedLaunch? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func currentProcess(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.process.processIdentifier == pid
    }

    func cancelRecovery(resetAttempts: Bool) {
        lock.lock()
        recoveryToken = UUID()
        if resetAttempts {
            recoveryAttempt = 0
        }
        lock.unlock()
    }

    func recoveryIsCurrent(_ token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoveryToken == token
    }

    func markExpectedStop(launchID: UUID?) {
        lock.lock()
        if let launchID, current?.id == launchID {
            current?.expectedStop = true
        }
        recoveryToken = UUID()
        recoveryAttempt = 0
        lock.unlock()
    }

    /// Exactly one of Foundation's termination handler and the explicit stop
    /// path records a launch. A stale handler from an older launch can never
    /// clear or overwrite a replacement process's state.
    func claimTermination(launchID: UUID) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard !handledLaunchIDs.contains(launchID), current?.id == launchID else {
            return nil
        }
        let expected = current?.expectedStop ?? false
        current = nil
        handledLaunchIDs.append(launchID)
        if handledLaunchIDs.count > 32 {
            handledLaunchIDs.removeFirst(handledLaunchIDs.count - 32)
        }
        return expected
    }

    func nextRecovery(launchedAt: Date, exitedAt: Date, policy: CoreRecoveryPolicy) -> (token: UUID, attempt: Int, delay: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        if exitedAt.timeIntervalSince(launchedAt) >= policy.stableInterval {
            recoveryAttempt = 0
        }
        guard recoveryAttempt < policy.backoffs.count else {
            return nil
        }
        let delay = policy.backoffs[recoveryAttempt]
        recoveryAttempt += 1
        let token = UUID()
        recoveryToken = token
        return (token, recoveryAttempt, delay)
    }
}

public struct CoreSupervisor: Sendable {
    private let paths: KumoPaths
    private let stateStore: CoreStateStore
    private let ownerTier: RuntimeOwnerTier
    private let processInspector: any CoreProcessInspecting
    private let recoveryPolicy: CoreRecoveryPolicy
    private let now: @Sendable () -> Date
    private let session: CoreSupervisionSession
    private let portInspector: any PortInspecting

    public init(paths: KumoPaths = KumoPaths(), ownerTier: RuntimeOwnerTier = .localSupervisor) {
        self.init(
            paths: paths,
            ownerTier: ownerTier,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: .default,
            now: Date.init,
            portInspector: nil
        )
    }

    init(paths: KumoPaths, ownerTier: RuntimeOwnerTier = .localSupervisor, portInspector: any PortInspecting) {
        self.init(
            paths: paths,
            ownerTier: ownerTier,
            processInspector: LiveCoreProcessInspector(),
            recoveryPolicy: .default,
            now: Date.init,
            portInspector: portInspector
        )
    }

    init(
        paths: KumoPaths,
        ownerTier: RuntimeOwnerTier = .localSupervisor,
        processInspector: any CoreProcessInspecting,
        recoveryPolicy: CoreRecoveryPolicy,
        now: @escaping @Sendable () -> Date = Date.init,
        portInspector: (any PortInspecting)? = nil
    ) {
        self.paths = paths
        self.stateStore = CoreStateStore(paths: paths)
        self.ownerTier = ownerTier
        self.processInspector = processInspector
        self.recoveryPolicy = recoveryPolicy
        self.now = now
        self.session = CoreSupervisionRegistry.shared.session(for: paths)
        self.portInspector = portInspector ?? LocalPortInspector()
    }

    @discardableResult
    public func start(configuration: CoreLaunchConfiguration) throws -> CoreStatus {
        session.cancelRecovery(resetAttempts: true)
        return try start(configuration: configuration, recovery: nil)
    }

    @discardableResult
    private func start(
        configuration: CoreLaunchConfiguration,
        recovery: (token: UUID, attempt: Int, delay: TimeInterval)?
    ) throws -> CoreStatus {
        if let recovery {
            guard session.recoveryIsCurrent(recovery.token) else {
                return try stateStore.load()
            }
        }
        try paths.prepare()

        let currentStatus = try status()
        if currentStatus.state == .running, let pid = currentStatus.pid {
            throw KumoError.coreAlreadyRunning(pid)
        }
        try checkPorts(configuration)

        try removeCorePIDFile()
        let corePath = try resolveCorePath(configuration.corePath)
        var launchConfiguration = configuration
        launchConfiguration.corePath = corePath
        appendRuntimeEvent(kind: "core.starting", message: "Starting Mihomo core at \(corePath).")

        // Build and validate a candidate without touching the last known-good
        // runtime file. Only a successful `mihomo -t` installs it atomically.
        let runtime = try validateConfiguration(launchConfiguration, corePath: corePath)

        if let recovery, !session.recoveryIsCurrent(recovery.token) {
            return try stateStore.load()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = launchArguments(for: runtime)
        rotateCoreLogIfNeeded()
        process.standardOutput = try logFileHandle()
        process.standardError = try logFileHandle()
        do {
            try process.run()
        } catch {
            let message = "Failed to start Mihomo core: \(error.localizedDescription)"
            try recordStartFailure(message, previous: currentStatus)
            throw KumoError.commandFailed(message)
        }

        let launchedAt = now()
        let processID = Int32(process.processIdentifier)
        let launchID = session.attach(process: process, configuration: launchConfiguration, launchedAt: launchedAt)

        do {
            try writeCorePID(processID)
            let status = CoreStatus(
                state: .running,
                pid: processID,
                corePath: corePath,
                ownerTier: ownerTier,
                mode: configuration.mode,
                endpoint: runtime.endpoint,
                proxyPorts: runtime.proxyPorts,
                systemProxyEnabled: currentStatus.systemProxyEnabled,
                runtimeSettings: configuration.runtimeSettings,
                systemProxySettings: currentStatus.systemProxySettings,
                previousSystemProxySnapshot: currentStatus.previousSystemProxySnapshot,
                serviceModeStatus: currentStatus.serviceModeStatus,
                tunStatus: currentStatus.tunStatus,
                readiness: .processLaunched,
                message: recovery == nil ? "Mihomo core started." : "Mihomo core recovered after an unexpected exit.",
                processStartTime: processInspector.snapshot(pid: processID)?.startedAt?.timeIntervalSince1970,
                lastExit: currentStatus.lastExit
            )
            try stateStore.save(status)
            // Foundation invokes this immediately if a short-lived core exited
            // before the handler was installed; the persisted pid is now in
            // place, so that callback cannot be overwritten by a later save.
            process.terminationHandler = { [self, launchConfiguration, launchedAt] process in
                processTerminated(
                    process,
                    launchID: launchID,
                    configuration: launchConfiguration,
                    launchedAt: launchedAt,
                    expectedOverride: nil
                )
            }
            appendRuntimeEvent(
                kind: recovery == nil ? "core.started" : "core.recovered",
                message: "Mihomo core started with pid \(processID)."
            )
            return status
        } catch {
            session.markExpectedStop(launchID: launchID)
            _ = terminateProcess(processID, expectedStart: processInspector.snapshot(pid: processID)?.startedAt?.timeIntervalSince1970)
            processTerminated(
                process,
                launchID: launchID,
                configuration: launchConfiguration,
                launchedAt: launchedAt,
                expectedOverride: true
            )
            throw error
        }
    }

    @discardableResult
    public func stop() throws -> CoreStatus {
        let launch = session.currentLaunch()
        session.markExpectedStop(launchID: launch?.id)
        var status = try stateStore.load()
        let pids = recordedPIDs(status: status)
        guard !pids.isEmpty else {
            status.state = .stopped
            status.pid = nil
            status.ownerTier = nil
            status.readiness = nil
            status.processStartTime = nil
            try removeCorePIDFile()
            try stateStore.save(status)
            appendRuntimeEvent(kind: "core.stopped", message: "Mihomo core was already stopped.")
            return status
        }

        var failures: [String] = []
        for pid in pids {
            let expectedStart = status.pid == pid ? status.processStartTime : nil
            switch processHealth(pid: pid, status: status) {
            case .dead, .identityMismatch:
                // A dead pid needs no signal. A reused pid is never signalled;
                // keep a failed record so the caller sees why it was refused.
                if case .identityMismatch(let reason) = processHealth(pid: pid, status: status) {
                    failures.append(reason)
                }
            case .unverified(let reason):
                failures.append(reason)
            case .alive(let snapshot):
                if !terminateProcess(pid, expectedStart: snapshot.startedAt?.timeIntervalSince1970 ?? expectedStart) {
                    failures.append("Failed to stop Mihomo core with pid \(pid); its identity changed or it did not exit.")
                }
            }
        }

        if let launch {
            processTerminated(
                launch.process,
                launchID: launch.id,
                configuration: launch.configuration,
                launchedAt: launch.launchedAt,
                expectedOverride: true
            )
            status.lastExit = (try? stateStore.load().lastExit) ?? status.lastExit
        } else if failures.isEmpty {
            let exit = CoreExit(
                time: now(),
                pid: status.pid,
                expected: true,
                message: "Mihomo core stopped by request."
            )
            status.lastExit = exit
        }

        guard failures.isEmpty else {
            status.state = .failed
            status.message = failures.joined(separator: " ")
            try stateStore.save(status)
            appendRuntimeEvent(kind: "core.stop_failed", message: status.message ?? "Failed to stop Mihomo core.")
            return status
        }

        status.state = .stopped
        status.pid = nil
        status.ownerTier = nil
        status.readiness = nil
        status.processStartTime = nil
        status.message = "Mihomo core stopped."
        try removeCorePIDFile()
        try stateStore.save(status)
        appendRuntimeEvent(kind: "core.stopped", message: "Mihomo core stopped.")
        return status
    }

    public func status() throws -> CoreStatus {
        var status = try stateStore.load()
        let pids = recordedPIDs(status: status)
        var unverified: (pid: Int32, reason: String)?

        for pid in pids {
            switch processHealth(pid: pid, status: status) {
            case .alive(let snapshot):
                if status.pid != pid || status.state != .running {
                    status.state = .running
                    status.pid = pid
                    status.readiness = status.readiness ?? .processLaunched
                    status.message = "Mihomo core is running."
                    appendRuntimeEvent(kind: "core.pid_recovered", message: "Recovered running Mihomo pid \(pid).")
                }
                status.processStartTime = snapshot.startedAt?.timeIntervalSince1970 ?? status.processStartTime
                try stateStore.save(status)
                return status
            case .unverified(let reason):
                unverified = (pid, reason)
            case .dead, .identityMismatch:
                continue
            }
        }

        if let unverified {
            status.state = .running
            status.pid = unverified.pid
            status.message = unverified.reason
            return status
        }

        if !pids.isEmpty {
            let wasActive = status.state == .running || status.state == .starting
            let reason = pids.contains(where: {
                if case .identityMismatch = processHealth(pid: $0, status: status) { return true }
                return false
            })
                ? "The recorded Mihomo pid was reused or now belongs to another process; Kumo refused to signal it."
                : "Mihomo is no longer running."
            if wasActive {
                let exit = CoreExit(time: now(), pid: status.pid, expected: false, message: reason)
                status.state = .failed
                status.lastExit = exit
                status.message = reason
                appendRuntimeEvent(kind: "core.exit_unexpected", message: reason)
            } else {
                status.state = .stopped
                status.message = "Mihomo core is not running."
                appendRuntimeEvent(kind: "core.stale_pid", message: "Cleared stale Mihomo pid records.")
            }
            status.pid = nil
            if status.state == .stopped {
                status.ownerTier = nil
            }
            status.readiness = nil
            status.processStartTime = nil
            try removeCorePIDFile()
            try stateStore.save(status)
        }
        return status
    }

    public func updateReadiness(_ readiness: CoreReadiness, message: String? = nil) throws -> CoreStatus {
        var status = try stateStore.load()
        status.readiness = readiness
        status.message = message ?? status.message
        try stateStore.save(status)
        appendRuntimeEvent(kind: "core.readiness", message: message ?? "Core readiness changed to \(readiness.rawValue).")
        return status
    }

    public func recentRuntimeEvents(limit: Int = 200) throws -> [RuntimeEventEntry] {
        guard FileManager.default.fileExists(atPath: paths.runtimeEventsFile.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let content = try String(contentsOf: paths.runtimeEventsFile, encoding: .utf8)
        return content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line -> RuntimeEventEntry? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(RuntimeEventEntry.self, from: data)
            }
    }

    public func discoverCoreCandidates(configuredPath: String? = nil) -> [CoreCandidate] {
        let fileManager = FileManager.default
        let names = ["mihomo", "mihomo-alpha", "clash", "clash-meta"]
        var candidates: [CoreCandidate] = []
        var seen = Set<String>()

        func append(_ path: String?, source: String) {
            guard let path, !path.isEmpty, fileManager.isExecutableFile(atPath: path), !seen.contains(path) else { return }
            seen.insert(path)
            candidates.append(CoreCandidate(name: URL(fileURLWithPath: path).lastPathComponent, path: path, sourceDescription: source))
        }

        append(configuredPath, source: "Selected")
        append(paths.managedCoreExecutable.path, source: "Managed")
        append(ProcessInfo.processInfo.environment["KUMO_MIHOMO_PATH"], source: "Environment")
        for name in names {
            append(Bundle.main.url(forResource: name, withExtension: nil)?.path, source: "Bundled")
        }
        for directory in searchDirectories() {
            for name in names {
                append(URL(fileURLWithPath: directory).appendingPathComponent(name).path, source: directory)
            }
            appendMatchingExecutables(in: directory, seen: &seen, candidates: &candidates)
        }
        return candidates
    }

    // MARK: - Configuration transactions

    func buildRuntimeConfiguration(_ configuration: CoreLaunchConfiguration) throws -> RuntimeConfig {
        try RuntimeConfigBuilder(
            endpoint: configuration.endpoint,
            proxyPorts: configuration.proxyPorts,
            mode: configuration.mode,
            runtimeSettings: configuration.runtimeSettings
        ).build(profile: configuration.profile, overrideYAMLs: configuration.overrideYAMLs)
    }

    /// Builds a candidate and asks the actual selected core to validate it.
    /// Installing remains the default for launch/reload transactions. Read-only
    /// validation uses an isolated temporary work directory and never installs
    /// the candidate or appends a runtime event.
    @discardableResult
    func validateConfiguration(
        _ configuration: CoreLaunchConfiguration,
        corePath explicitCorePath: String? = nil,
        install: Bool = true
    ) throws -> RuntimeConfig {
        let corePath = try explicitCorePath ?? resolveCorePath(configuration.corePath)
        let runtime = try buildRuntimeConfiguration(configuration)
        let fileManager = FileManager.default
        let validationDirectory: URL
        if install {
            try fileManager.createDirectory(at: paths.workDirectory, withIntermediateDirectories: true)
            validationDirectory = paths.workDirectory
        } else {
            validationDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("kumo-config-validation-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: validationDirectory, withIntermediateDirectories: true)
        }
        let candidate = validationDirectory.appendingPathComponent(".config-candidate-\(UUID().uuidString).yaml")
        defer {
            if install {
                try? fileManager.removeItem(at: candidate)
            } else {
                try? fileManager.removeItem(at: validationDirectory)
            }
        }
        try Data(runtime.yaml.utf8).write(to: candidate, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: corePath)
        process.arguments = ["-t", "-d", validationDirectory.path, "-f", candidate.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            throw KumoError.configurationValidationFailed(error.localizedDescription)
        }
        guard exited.wait(timeout: .now() + 15) == .success else {
            if process.isRunning { process.terminate() }
            // NSTask only becomes fully reaped after its termination is waited
            // on. Without this, a timed-out validator can remain a zombie even
            // though SIGTERM successfully ended the process.
            process.waitUntilExit()
            throw KumoError.configurationValidationFailed("mihomo -t did not finish within 15 seconds.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = message.isEmpty ? "mihomo -t exited with status \(process.terminationStatus)." : message
            if install {
                appendRuntimeEvent(kind: "config.validation_failed", message: detail)
            }
            throw KumoError.configurationValidationFailed(detail)
        }

        if install {
            try Data(runtime.yaml.utf8).write(to: paths.runtimeConfigFile, options: .atomic)
            for warning in runtime.warnings {
                appendRuntimeEvent(kind: "config.dns_warning", message: warning)
            }
        }
        return runtime
    }

    func runtimeConfigurationData() -> Data? {
        try? Data(contentsOf: paths.runtimeConfigFile)
    }

    func restoreRuntimeConfiguration(_ data: Data?) throws {
        if let data {
            try data.write(to: paths.runtimeConfigFile, options: .atomic)
        } else if FileManager.default.fileExists(atPath: paths.runtimeConfigFile.path) {
            try FileManager.default.removeItem(at: paths.runtimeConfigFile)
        }
    }

    func failureMessage(_ fallback: String) -> String {
        if let status = try? stateStore.load(), let exit = status.lastExit, !exit.expected {
            return exit.message
        }
        guard let fatal = recentFatalCoreLog() else { return fallback }
        return "\(fallback) \(fatal)"
    }

    // MARK: - Exit handling and bounded recovery

    private func processTerminated(
        _ process: Process,
        launchID: UUID,
        configuration: CoreLaunchConfiguration,
        launchedAt: Date,
        expectedOverride: Bool?
    ) {
        guard let claimedExpected = session.claimTermination(launchID: launchID) else { return }
        let expected = expectedOverride ?? claimedExpected
        let pid = Int32(process.processIdentifier)
        let exitCode: Int32?
        let signal: Int32?
        // The explicit stop path can observe waitpid exit before Foundation
        // updates NSTask. Reading terminationReason while isRunning is true
        // raises NSInvalidArgumentException, so leave code/signal unknown in
        // that narrow race; Foundation's handler will already have recorded
        // them when it won the claim.
        if process.isRunning {
            exitCode = nil
            signal = nil
        } else {
            switch process.terminationReason {
            case .exit:
                exitCode = process.terminationStatus
                signal = nil
            case .uncaughtSignal:
                exitCode = nil
                signal = process.terminationStatus
            @unknown default:
                exitCode = process.terminationStatus
                signal = nil
            }
        }
        let base = expected
            ? "Mihomo core exited after an expected stop."
            : exitDescription(pid: pid, exitCode: exitCode, signal: signal)
        let exit = CoreExit(
            time: now(),
            pid: pid,
            exitCode: exitCode,
            signal: signal,
            expected: expected,
            message: withRecentFatal(base)
        )

        do {
            var status = try stateStore.load()
            guard status.pid == nil || status.pid == pid else { return }
            status.lastExit = exit
            status.pid = nil
            status.processStartTime = nil
            status.readiness = nil
            if expected {
                status.state = .stopped
                status.ownerTier = nil
            } else {
                status.state = .failed
                // Preserve ownerTier in failed state: notifications and status
                // readers need to know which tier is recovering the core.
            }
            status.message = exit.message
            try stateStore.save(status)
        } catch {
            supervisorLogger.warning("Unable to persist core exit: \(error.localizedDescription, privacy: .public)")
        }
        if readCorePID() == pid {
            try? removeCorePIDFile()
        }
        appendRuntimeEvent(kind: expected ? "core.exit_expected" : "core.exit_unexpected", message: exit.message)
        guard !expected else { return }

        guard let recovery = session.nextRecovery(launchedAt: launchedAt, exitedAt: exit.time, policy: recoveryPolicy) else {
            appendRuntimeEvent(kind: "core.recovery_exhausted", message: "Automatic recovery stopped after \(recoveryPolicy.backoffs.count) attempts.")
            return
        }
        appendRuntimeEvent(
            kind: "core.recovery_scheduled",
            message: "Recovery attempt \(recovery.attempt) of \(recoveryPolicy.backoffs.count) scheduled in \(recovery.delay) seconds."
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + recovery.delay) { [self] in
            guard session.recoveryIsCurrent(recovery.token) else { return }
            do {
                _ = try start(configuration: configuration, recovery: recovery)
            } catch {
                let message = failureMessage("Automatic recovery attempt \(recovery.attempt) failed: \(error.localizedDescription)")
                appendRuntimeEvent(kind: "core.recovery_failed", message: message)
                if var status = try? stateStore.load() {
                    status.state = .failed
                    status.message = message
                    try? stateStore.save(status)
                }
            }
        }
    }

    private func exitDescription(pid: Int32, exitCode: Int32?, signal: Int32?) -> String {
        if let signal {
            return "Mihomo core (pid \(pid)) exited unexpectedly after signal \(signal)."
        }
        if let exitCode {
            return "Mihomo core (pid \(pid)) exited unexpectedly with code \(exitCode)."
        }
        return "Mihomo core (pid \(pid)) exited unexpectedly."
    }

    private func withRecentFatal(_ message: String) -> String {
        guard let fatal = recentFatalCoreLog() else { return message }
        return "\(message) \(fatal)"
    }

    private func recentFatalCoreLog() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: paths.coreLogFile) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let window = min(size, 256 * 1024)
        do {
            try handle.seek(toOffset: size - window)
        } catch {
            return nil
        }
        guard let tail = try? handle.readToEnd() else { return nil }
        return tail
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("level=fatal") || lower.contains("fatal error") || lower.contains("fatal:")
            }
            .last
    }

    private func recordStartFailure(_ message: String, previous: CoreStatus) throws {
        var status = previous
        status.state = .failed
        status.pid = nil
        status.ownerTier = nil
        status.readiness = nil
        status.processStartTime = nil
        status.message = message
        try stateStore.save(status)
        appendRuntimeEvent(kind: "core.failed", message: message)
    }

    // MARK: - Process identity and signals

    private enum ProcessHealth {
        case alive(CoreProcessSnapshot)
        case dead
        case identityMismatch(String)
        case unverified(String)
    }

    private func processHealth(pid: Int32, status: CoreStatus) -> ProcessHealth {
        guard let snapshot = processInspector.snapshot(pid: pid), !snapshot.isZombie else {
            return .dead
        }
        if let expected = status.pid == pid ? status.processStartTime : nil {
            guard let actual = snapshot.startedAt else {
                return .unverified("Mihomo pid \(pid) exists but its identity cannot be verified; stop it through its owning tier.")
            }
            guard abs(actual.timeIntervalSince1970 - expected) < 0.002 else {
                return .identityMismatch("Recorded Mihomo pid \(pid) was reused by another process; Kumo refused to signal it.")
            }
            return .alive(snapshot)
        }
        if session.currentProcess(pid: pid) {
            return .alive(snapshot)
        }
        if let corePath = status.corePath, let executablePath = snapshot.executablePath,
           canonicalPath(executablePath) == canonicalPath(corePath) {
            return .alive(snapshot)
        }
        return .identityMismatch("Recorded pid \(pid) has no matching Mihomo identity; Kumo refused to signal it.")
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func terminateProcess(_ pid: Int32, expectedStart: TimeInterval?) -> Bool {
        let steps: [(signal: Int32, timeout: TimeInterval)] = [(SIGINT, 1.0), (SIGTERM, 2.0), (SIGKILL, 1.0)]
        for step in steps {
            if let snapshot = processInspector.snapshot(pid: pid), !snapshot.isZombie,
               let expectedStart, let actual = snapshot.startedAt,
               abs(actual.timeIntervalSince1970 - expectedStart) >= 0.002 {
                return false
            }
            if Darwin.kill(pid, step.signal) != 0 {
                if errno == EPERM || errno == ESRCH { return errno == ESRCH }
                return false
            }
            if waitForExit(pid, timeout: step.timeout) { return true }
        }
        guard let snapshot = processInspector.snapshot(pid: pid) else { return true }
        return snapshot.isZombie
    }

    private func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasProcessExited(pid) { return true }
            usleep(100_000)
        }
        return hasProcessExited(pid)
    }

    private func hasProcessExited(_ pid: Int32) -> Bool {
        var waitStatus: Int32 = 0
        let result = Darwin.waitpid(pid, &waitStatus, WNOHANG)
        if result == pid { return true }
        if result == 0 { return false }
        guard let snapshot = processInspector.snapshot(pid: pid) else { return true }
        return snapshot.isZombie
    }

    // MARK: - Port checks

    private func checkPorts(_ configuration: CoreLaunchConfiguration) throws {
        let mixedHost = configuration.runtimeSettings.allowLAN ? "0.0.0.0" : "127.0.0.1"
        let conflicts = portInspector.conflicts(
            mixedHost: mixedHost,
            mixedPort: configuration.runtimeSettings.mixedPort,
            controllerHost: configuration.endpoint.host,
            controllerPort: configuration.endpoint.port
        )
        if !conflicts.isEmpty {
            throw KumoError.portConflicts(conflicts)
        }
    }

    private func portIsOccupied(_ host: String, _ port: Int) -> Bool {
        guard port > 0, port <= 65_535, !host.isEmpty else { return false }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let resolution = resolved else { return false }
        defer { freeaddrinfo(resolution) }
        var candidate: UnsafeMutablePointer<addrinfo>? = resolution
        while let current = candidate {
            if connectSucceeds(current.pointee, timeout: 1.0) { return true }
            candidate = current.pointee.ai_next
        }
        return false
    }

    private func connectSucceeds(_ address: addrinfo, timeout: TimeInterval) -> Bool {
        let socketFD = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags >= 0, fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else { return false }
        if connect(socketFD, address.ai_addr, address.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&descriptor, 1, Int32((timeout * 1000).rounded())) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }

    // MARK: - Files and logging

    private func resolveCorePath(_ configuredPath: String?) throws -> String {
        if let candidate = discoverCoreCandidates(configuredPath: configuredPath).first {
            return candidate.path
        }
        throw KumoError.coreNotFound(configuredPath ?? "mihomo")
    }

    private func launchArguments(for runtime: RuntimeConfig) -> [String] {
        var arguments = ["-d", paths.workDirectory.path, "-ext-ctl", "\(runtime.endpoint.host):\(runtime.endpoint.port)"]
        if !runtime.endpoint.secret.isEmpty {
            arguments.append(contentsOf: ["-secret", runtime.endpoint.secret])
        }
        return arguments
    }

    private func recordedPIDs(status: CoreStatus) -> [Int32] {
        var result: [Int32] = []
        var seen = Set<Int32>()
        for pid in [status.pid, readCorePID()] {
            if let pid, pid > 0, seen.insert(pid).inserted { result.append(pid) }
        }
        return result
    }

    private func readCorePID() -> Int32? {
        guard let content = try? String(contentsOf: paths.corePIDFile, encoding: .utf8) else { return nil }
        return Int32(content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeCorePID(_ pid: Int32) throws {
        try FileManager.default.createDirectory(at: paths.workDirectory, withIntermediateDirectories: true)
        try "\(pid)\n".write(to: paths.corePIDFile, atomically: true, encoding: .utf8)
    }

    private func removeCorePIDFile() throws {
        guard FileManager.default.fileExists(atPath: paths.corePIDFile.path) else { return }
        try FileManager.default.removeItem(at: paths.corePIDFile)
    }

    private func rotateCoreLogIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: paths.coreLogFile.path),
              let size = attributes[.size] as? Int, size > 0 else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = paths.logsDirectory.appendingPathComponent("core-\(formatter.string(from: now())).log")
        try? fileManager.moveItem(at: paths.coreLogFile, to: destination)
    }

    private func logFileHandle() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: paths.coreLogFile.path) {
            FileManager.default.createFile(atPath: paths.coreLogFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: paths.coreLogFile)
        try handle.seekToEnd()
        return handle
    }

    private func appendRuntimeEvent(kind: String, message: String) {
        do {
            try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(RuntimeEventEntry(kind: kind, message: message))
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: paths.runtimeEventsFile.path) {
                FileManager.default.createFile(atPath: paths.runtimeEventsFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: paths.runtimeEventsFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            supervisorLogger.warning("Unable to append runtime event \(kind, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func searchDirectories() -> [String] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin", "\(home)/bin"]
        return Array(Set(pathDirectories + commonDirectories)).sorted()
    }

    private func appendMatchingExecutables(in directory: String, seen: inout Set<String>, candidates: inout [CoreCandidate]) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for file in files where file.hasPrefix("mihomo") || file.hasPrefix("clash") {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(file).path
            guard FileManager.default.isExecutableFile(atPath: path), !seen.contains(path) else { continue }
            seen.insert(path)
            candidates.append(CoreCandidate(name: file, path: path, sourceDescription: directory))
        }
    }
}
