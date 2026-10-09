import Foundation
import os

let shutdownLogger = Logger(subsystem: "io.kumo.KumoApp", category: "shutdown")

/// Reports caller-side readiness bookkeeping that was skipped because the
/// helper-owned state is the authoritative record (Issue #3).
private let readinessLogger = Logger(subsystem: "io.kumo.KumoApp", category: "readiness")

/// Result of a best-effort shutdown attempt. `status` is the most recent
/// observable core status (falls back to the on-disk state store, then a
/// stopped `CoreStatus()`). `diagnostics` lists every step that failed,
/// stage-prefixed, so callers can surface or log them without losing the
/// later errors to the first one — matching Sparkle's
/// `Promise.all([disable, stopCore])` + per-branch try/catch pattern.
public struct ShutdownResult: Sendable {
    public let status: CoreStatus
    public let diagnostics: [String]

    public init(status: CoreStatus, diagnostics: [String] = []) {
        self.status = status
        self.diagnostics = diagnostics
    }

    public var failed: Bool { !diagnostics.isEmpty }
}

public struct KumoController: Sendable {
    public let paths: KumoPaths
    let profileRepository: ProfileRepository
    /// Memoizes the profile YAML parses the app asks for repeatedly; see
    /// `ProfileParseCache`.
    let profileParseCache: ProfileParseCache
    let overrideRepository: OverrideRepository
    let supervisor: CoreSupervisor
    let stateStore: CoreStateStore
    let systemProxyController: SystemProxyController
    let coreInstaller: CoreInstaller
    let subStoreManager: SubStoreManager
    let backupManager: KumoBackupManager
    let appUpdateManager: AppUpdateManager
    let appUpdateInstaller: AppUpdateInstaller
    let preferencesStore: UserPreferencesStore
    let subStoreSupervisor: SubStoreSupervisor
    let serviceManager: KumoServiceManager
    let userAgentManager: KumoUserAgentManager
    /// Selects the runtime tier for every lifecycle, TUN and system-proxy
    /// operation. See `BackendRouter`.
    let router: BackendRouter
    /// Test seam: replaces `serviceManager.status()` so routing tests can
    /// simulate a reachable privileged tier without installing the helper.
    let serviceModeStatusProvider: (@Sendable () -> ServiceModeStatus)?
    /// Test seam: replaces the real per-tier lifecycle calls so handoff
    /// success and rollback can be exercised without sockets or spawns.
    let tierOperations: TierOperationsOverride?
    /// Test seam: replaces the controller HTTP readiness wait.
    let readinessWaiter: (@Sendable () async throws -> Void)?
    let useServiceBackend: Bool

    public init(
        paths: KumoPaths = KumoPaths(),
        useServiceBackend: Bool = true,
        ownerTier: RuntimeOwnerTier = .localSupervisor,
        systemProxyCommandRunner: SystemProxyCommandRunner = .live
    ) {
        self.init(
            paths: paths,
            useServiceBackend: useServiceBackend,
            ownerTier: ownerTier,
            systemProxyCommandRunner: systemProxyCommandRunner,
            reachability: nil,
            serviceModeStatusProvider: nil,
            tierOperations: nil,
            readinessWaiter: nil
        )
    }

    init(
        paths: KumoPaths,
        useServiceBackend: Bool,
        ownerTier: RuntimeOwnerTier = .localSupervisor,
        systemProxyCommandRunner: SystemProxyCommandRunner,
        reachability: BackendReachability?,
        serviceModeStatusProvider: (@Sendable () -> ServiceModeStatus)?,
        tierOperations: TierOperationsOverride?,
        readinessWaiter: (@Sendable () async throws -> Void)?
    ) {
        self.paths = paths
        self.profileRepository = ProfileRepository(paths: paths)
        self.profileParseCache = ProfileParseCache(profiles: ProfileRepository(paths: paths))
        self.overrideRepository = OverrideRepository(paths: paths)
        self.supervisor = CoreSupervisor(paths: paths, ownerTier: ownerTier)
        self.stateStore = CoreStateStore(paths: paths)
        self.systemProxyController = SystemProxyController(paths: paths, commandRunner: systemProxyCommandRunner)
        self.coreInstaller = CoreInstaller(paths: paths)
        self.subStoreManager = SubStoreManager(paths: paths)
        self.backupManager = KumoBackupManager(paths: paths)
        self.appUpdateManager = AppUpdateManager()
        self.appUpdateInstaller = AppUpdateInstaller(paths: paths)
        self.preferencesStore = UserPreferencesStore(paths: paths)
        self.subStoreSupervisor = SubStoreSupervisor(paths: paths)
        self.serviceManager = KumoServiceManager(paths: paths)
        self.userAgentManager = KumoUserAgentManager(paths: paths)
        self.router = BackendRouter(
            reachability: reachability ?? .live(paths: paths, useServiceBackend: useServiceBackend),
            allowsServiceBackend: useServiceBackend
        )
        self.serviceModeStatusProvider = serviceModeStatusProvider
        self.tierOperations = tierOperations
        self.readinessWaiter = readinessWaiter
        self.useServiceBackend = useServiceBackend
    }

    public func status() throws -> CoreStatus {
        let decision = router.decideCoreBackend(tunEnabled: currentTunEnabled())
        if let client = serviceClient(for: decision) {
            do {
                return try client.sendDecodable(client.statusRequest(), as: CoreStatus.self)
            } catch {
                // A tier that answered the reachability probe can still fail
                // this call (restart, socket churn). The shared state file plus
                // pid recovery is the fallback read, so a live core is never
                // reported stopped because of a momentary IPC failure.
                routingLogger.warning(
                    "Status read through \(decision.backend?.rawValue ?? "none", privacy: .public) failed; falling back to the shared state: \(error.localizedDescription, privacy: .public)"
                )
                return try supervisor.status()
            }
        }
        return try supervisor.status()
    }

    public func currentProfile() throws -> ProfileSummary {
        try profileRepository.currentProfileSummary()
    }

    public func profiles() throws -> [ProfileSummary] {
        try profileRepository.listProfiles()
    }

    public func setCurrentProfile(id: String) throws {
        try profileRepository.setCurrentProfile(id: id)
    }

    public func coreCandidates() throws -> [CoreCandidate] {
        let status = try stateStore.load()
        return supervisor.discoverCoreCandidates(configuredPath: status.corePath)
    }

    public func setCorePath(_ path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw KumoError.coreNotFound(path)
        }

        var status = try stateStore.load()
        status.corePath = path
        try stateStore.save(status)
    }

    /// Clear any explicit core path so the supervisor falls back to auto-discovery
    /// (managed core, env, $PATH, bundled binaries).
    public func clearCorePath() throws {
        var status = try stateStore.load()
        status.corePath = nil
        try stateStore.save(status)
    }

    @discardableResult
    public func installManagedCore() async throws -> CoreInstallResult {
        let result = try await coreInstaller.installLatestMihomo()
        try setCorePath(result.path)
        return result
    }

    @discardableResult
    public func start(corePath: String? = nil) throws -> CoreStatus {
        if corePath == nil {
            return try performTierStart(try requiredCoreBackend())
        }
        return try startLocalCore(corePath: corePath)
    }

    /// Direct-mode launch: generate the runtime config from the current profile
    /// and run the core as a child of this process. Routed callers reach this
    /// only when `BackendRouter` selects the local supervisor.
    func startLocalCore(corePath: String?) throws -> CoreStatus {
        let currentStatus = try normalizedStatusForLaunch()
        let profile = try profileRepository.loadDefaultProfile()
        let overrideYAMLs = try overrideRepository.activeYAMLs()
        return try supervisor.start(
            configuration: CoreLaunchConfiguration(
                corePath: corePath ?? currentStatus.corePath,
                profile: profile,
                overrideYAMLs: overrideYAMLs,
                endpoint: currentStatus.endpoint,
                proxyPorts: currentStatus.proxyPorts,
                mode: currentStatus.mode,
                runtimeSettings: runtimeSettings(for: currentStatus)
            )
        )
    }

    @discardableResult
    public func stop() throws -> CoreStatus {
        try performTierStop(try requiredCoreBackend())
    }

    /// Best-effort shutdown of whichever runtime is active (routed through the
    /// tier that owns the core: root daemon, user agent, or the in-app
    /// supervisor). Disables Kumo-managed system proxy state and stops the
    /// running Mihomo core. Never throws — every failed step is recorded in the
    /// returned `ShutdownResult.diagnostics` and the next step is still
    /// attempted, so the caller is free to clear UI state and exit even
    /// when an error occurred. Includes synchronous-networksetup and local
    /// supervisor fallbacks for the helper-IPC failure case.
    @discardableResult
    public func shutdownActiveRuntime() async -> ShutdownResult {
        var diagnostics: [String] = []
        var latestStatus: CoreStatus
        do {
            latestStatus = try status()
        } catch {
            diagnostics.append(formatDiagnostic(stage: "status", error: error))
            latestStatus = (try? stateStore.load()) ?? CoreStatus()
        }

        if latestStatus.systemProxyEnabled {
            do {
                _ = try await setSystemProxy(false)
                latestStatus.systemProxyEnabled = false
            } catch {
                diagnostics.append(formatDiagnostic(stage: "system-proxy", error: error))
                do {
                    let configuration = fallbackSystemProxyConfiguration(for: latestStatus)
                    _ = try systemProxyController.disableSynchronously(configuration: configuration)
                    latestStatus.systemProxyEnabled = false
                } catch {
                    diagnostics.append(formatDiagnostic(stage: "system-proxy-fallback", error: error))
                }
            }
        }

        latestStatus = (try? status()) ?? latestStatus
        if latestStatus.state == .running || latestStatus.pid != nil {
            do {
                latestStatus = try stop()
            } catch {
                diagnostics.append(formatDiagnostic(stage: "stop", error: error))
                do {
                    latestStatus = try supervisor.stop()
                } catch {
                    diagnostics.append(formatDiagnostic(stage: "stop-fallback", error: error))
                }
            }
        }

        latestStatus = (try? status()) ?? latestStatus
        if latestStatus.state == .stopped {
            // A successful stop ends ownership. The stopping tier clears the
            // record in its own write; this best-effort clear also covers a
            // tier that predates ownership recording, so a stale record can
            // never outlive the core it described.
            latestStatus.ownerTier = nil
            recordCoreOwnership(nil)
        }
        return ShutdownResult(status: latestStatus, diagnostics: diagnostics)
    }

    public func restart(corePath: String? = nil) throws -> CoreStatus {
        if corePath == nil {
            switch try requiredCoreBackend() {
            case .rootService:
                guard let client = rootServiceClient() else {
                    throw KumoError.serviceUnavailable("Kumo Helper is not reachable.")
                }
                return try client.sendDecodable(client.restartCoreRequest(), as: CoreStatus.self)
            case .userAgent:
                guard let client = userAgentClient() else {
                    throw KumoError.serviceUnavailable("The Kumo agent is not reachable.")
                }
                return try client.sendDecodable(client.restartCoreRequest(), as: CoreStatus.self)
            case .localSupervisor:
                _ = try stop()
                return try start(corePath: nil)
            }
        }
        _ = try stop()
        return try start(corePath: corePath)
    }

    public func setMode(_ mode: OutboundMode) async throws {
        var status = try stateStore.load()
        status.mode = mode
        try stateStore.save(status)

        if status.state == .running {
            try await MihomoControllerClient(endpoint: status.endpoint).setMode(mode)
        }
    }

    public func updateRuntimeSettings(_ settings: CoreRuntimeSettings) async throws {
        var status = try stateStore.load()
        status.runtimeSettings = settings
        status.proxyPorts.mixedPort = settings.mixedPort
        try stateStore.save(status)

        if status.state == .running {
            try await MihomoControllerClient(endpoint: status.endpoint).patchConfiguration(runtimePatch(for: settings))
        }

        if status.systemProxyEnabled {
            _ = try await setSystemProxy(true)
        }
    }

    public func setControllerSecret(_ secret: String) throws {
        var status = try stateStore.load()
        status.endpoint.secret = secret
        try stateStore.save(status)
    }

    public func proxyGroups() async throws -> [ProxyGroup] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).proxyGroups()
    }

    public func coreConfiguration() async throws -> CoreConfigurationSnapshot {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).configuration()
    }

    public func waitForControllerReady(maxAttempts: Int = 30, intervalNanoseconds: UInt64 = 200_000_000) async throws {
        let status = try stateStore.load()
        let client = MihomoControllerClient(endpoint: status.endpoint)
        var lastError: Error?
        var controllerAnswered = false

        for _ in 0..<maxAttempts {
            do {
                _ = try await client.version()
                controllerAnswered = true
                break
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }

        guard controllerAnswered else {
            throw lastError ?? KumoError.coreNotRunning
        }

        // The readiness bookkeeping runs only after the controller proved it is
        // up, so a failure here must not be mistaken for "never became ready";
        // see `recordControllerReadiness()` for who may ignore it.
        try recordControllerReadiness()
    }

    /// Records `controllerReady` for the runtime the caller just started.
    ///
    /// The two modes have different state authority, and the distinction is
    /// deliberate:
    ///
    /// - Socket tiers (root daemon or user agent): the tier owns `state.json`,
    ///   the pid record and the runtime event log, and it is the authoritative
    ///   writer. On a fresh service-mode install the helper created those as
    ///   root, so a non-root caller-side write is denied (Issue #3). The core
    ///   is demonstrably ready at this point, so the denial degrades to a
    ///   warning instead of turning a successful `start` into a failure.
    /// - Direct mode: no daemon owns the state. The supervisor's own record is
    ///   what later `status()`/`stop()` calls act on, so a persistence failure
    ///   must still throw — a silently unrecorded core is an unmanageable core.
    private func recordControllerReadiness() throws {
        switch router.decideCoreBackend(tunEnabled: currentTunEnabled()) {
        case .backend(.localSupervisor):
            _ = try supervisor.updateReadiness(.controllerReady, message: "Mihomo controller is ready.")
        default:
            do {
                _ = try supervisor.updateReadiness(.controllerReady, message: "Mihomo controller is ready.")
            } catch {
                readinessLogger.warning(
                    "Tier-owned state is authoritative; skipping caller-side readiness bookkeeping: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public func rules() async throws -> [RuleEntry] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).rules()
    }

    public func setRuleEnabled(index: Int, isEnabled: Bool) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).setRulesDisabled([index: !isEnabled])
    }

    public func connections() async throws -> [ConnectionEntry] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).connections()
    }

    public func closeConnection(id: String) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).closeConnection(id: id)
    }

    public func closeConnections(matchingProxy proxy: String? = nil) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).closeConnections(matchingProxy: proxy)
    }

    public func selectProxy(group: String, name: String) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).selectProxy(group: group, name: name)
    }

    public func proxyProviders() async throws -> [ProxyProviderEntry] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).proxyProviders()
    }

    public func updateProxyProvider(name: String) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).updateProxyProvider(name: name)
    }

    public func ruleProviders() async throws -> [RuleProviderEntry] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).ruleProviders()
    }

    public func updateRuleProvider(name: String) async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).updateRuleProvider(name: name)
    }

    public func upgradeGeoData() async throws {
        let status = try stateStore.load()
        try await MihomoControllerClient(endpoint: status.endpoint).upgradeGeoData()
    }

    public func testProxyDelay(proxy: String, testURL: String? = nil) async throws -> Int? {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).proxyDelay(proxy: proxy, testURL: testURL)
    }

    public func testGroupDelay(group: ProxyGroup) async throws -> [ProxyNode] {
        let status = try stateStore.load()
        return try await MihomoControllerClient(endpoint: status.endpoint).groupDelay(group: group)
    }

    /// Downloads the subscription at `url` and returns the profile content.
    ///
    /// Dedupe semantics: when a profile with the same remote URL already
    /// exists, it is refreshed in place through the id path — same id, no
    /// duplicate profile, and neither the current selection nor the stored
    /// auto-update preference is changed. Only when no profile matches is a
    /// new profile imported, made current and seeded with auto-update enabled
    /// (the historical behavior). `useProxy` forces the fetch through the
    /// local Mihomo proxy and requires a running core; an existing profile's
    /// stored proxy preference applies otherwise.
    public func refreshProfile(from url: URL, useProxy: Bool = false) async throws -> Profile {
        if let existing = try profileRepository.findProfile(byRemoteURL: url) {
            let summary = try await refreshProfile(id: existing.id, useProxy: useProxy ? true : nil)
            return try profileRepository.loadProfile(id: summary.id)
        }
        let status = try supervisor.status()
        let proxyPort = status.state == .running ? status.proxyPorts.mixedPort : nil
        let summary = try await profileRepository.saveRemoteProfile(
            from: url,
            useProxy: useProxy,
            proxyPort: proxyPort
        )
        return try profileRepository.loadProfile(id: summary.id)
    }

    public func importProfile(from url: URL) throws -> ProfileSummary {
        let profile = try profileRepository.importLocalProfile(from: url)
        return try profileRepository.saveProfile(profile)
    }

    public func profileContent(id: String) throws -> String {
        try profileRepository.profileContent(id: id)
    }

    /// Parses profile YAML to prove it is a well-formed mapping before an
    /// edit writes it. Throws `KumoError.invalidArguments` with the parser
    /// message otherwise.
    public func validateProfileYAML(_ rawYAML: String) throws {
        try profileRepository.validateProfileYAML(rawYAML)
    }

    /// Proxy groups parsed from the profile's `proxy-groups:` section, memoized
    /// on the profile file's identity. Used for the stopped-core sidebar preview.
    public func profileProxyGroups(id: String) async throws -> [ProxyGroup] {
        try await profileParseCache.proxyGroups(profileID: id)
    }

    /// Outbound nodes parsed from the profile's `proxies:` section, memoized on
    /// the profile file's identity. Used for GeoIP country detection.
    public func profileNodes(id: String) async throws -> [String: ProfileNodeInfo] {
        try await profileParseCache.nodes(profileID: id)
    }

    public func overrides() throws -> [OverrideItem] {
        try overrideRepository.listOverrides()
    }

    public func overrideContent(id: String) throws -> String {
        try overrideRepository.content(id: id)
    }

    @discardableResult
    public func addLocalOverride(name: String, format: OverrideFormat, content: String, isGlobal: Bool = false) throws -> OverrideItem {
        try overrideRepository.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
    }

    @discardableResult
    public func addRemoteOverride(url: URL, name: String? = nil, format: OverrideFormat = .yaml, fingerprint: String? = nil, isGlobal: Bool = false) async throws -> OverrideItem {
        try await overrideRepository.addRemoteOverride(url: url, name: name, format: format, fingerprint: fingerprint, isGlobal: isGlobal)
    }

    public func updateOverride(_ item: OverrideItem, content: String? = nil) throws {
        try overrideRepository.updateOverride(item, content: content)
    }

    public func deleteOverride(id: String) throws {
        try overrideRepository.deleteOverride(id: id)
    }

    public func reorderOverrides(ids: [String]) throws {
        try overrideRepository.reorderOverrides(ids: ids)
    }

    @discardableResult
    public func updateProfile(
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) throws -> ProfileSummary {
        try profileRepository.updateProfile(
            id: id,
            name: name,
            remoteURL: remoteURL,
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            rawYAML: rawYAML
        )
    }

    @discardableResult
    public func deleteProfile(id: String) throws -> Bool {
        try profileRepository.deleteProfile(id: id)
    }

    /// Refreshes one profile in place, preserving its id, name, auto-update
    /// and proxy preferences. Sub-Store-managed profiles re-download through
    /// Sub-Store so their Sub-Store metadata survives; everything else
    /// re-downloads from its stored subscription URL.
    ///
    /// Pass `useProxy` to force the fetch through the local Mihomo proxy for
    /// this refresh (requires a running core); `nil` keeps the profile's
    /// stored proxy preference. A profile without a stored subscription URL
    /// fails with `KumoError.invalidArguments`.
    @discardableResult
    public func refreshProfile(id: String, useProxy: Bool? = nil) async throws -> ProfileSummary {
        if let profile = try profileRepository.listProfiles().first(where: { $0.id == id }),
           profile.isSubStoreManaged {
            return try await refreshSubStoreProfile(id: id)
        }
        let status = try supervisor.status()
        let proxyPort = status.state == .running ? status.proxyPorts.mixedPort : nil
        return try await profileRepository.refreshRemoteProfile(id: id, useProxy: useProxy, proxyPort: proxyPort)
    }

    /// Refreshes every profile whose subscription is due for its next
    /// automatic update, in id order.
    ///
    /// Sub-Store-managed profiles refresh through `refreshSubStoreProfile`
    /// rather than their raw download URL: the URL path rebuilds metadata
    /// from the fetched document and would drop the Sub-Store ownership
    /// record. `now` is injectable so tests can force due profiles without
    /// waiting out the interval.
    @discardableResult
    public func refreshDueProfiles(now: Date = Date()) async throws -> [ProfileSummary] {
        var refreshed: [ProfileSummary] = []
        for id in try profileRepository.dueRemoteProfileIDs(now: now) {
            refreshed.append(try await refreshProfile(id: id))
        }
        return refreshed
    }

    /// Byte window read from the end of `core.log` for each snapshot. Mihomo
    /// appends to this file for the whole lifetime of a session (hundreds of
    /// megabytes are normal), so only the tail is ever read.
    static let recentLogByteWindow = 256 * 1024

    /// Reads the tail of `core.log` and returns the last `limit` complete
    /// lines. Entries carry a content-derived id — the message hash plus the
    /// per-message occurrence counter inside this slice — so ids stay stable
    /// across refreshes instead of being renumbered by position.
    public func recentLogs(limit: Int = 300) throws -> [LogEntry] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: paths.coreLogFile.path) else {
            return []
        }

        let handle = try FileHandle(forReadingFrom: paths.coreLogFile)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let window = UInt64(Self.recentLogByteWindow)
        let readSize = min(fileSize, window)
        let startedMidFile = fileSize > window
        try handle.seek(toOffset: fileSize - readSize)

        let data = try handle.readToEnd() ?? Data()
        // 0x0A (line feed) never appears inside a UTF-8 multi-byte sequence,
        // so splitting the raw bytes is encoding-safe.
        var lines = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)

        // When the window starts mid-file its first line is almost always a
        // truncated fragment; drop it so callers only ever see whole lines.
        if startedMidFile, !lines.isEmpty {
            lines.removeFirst()
        }

        var occurrences: [String: Int] = [:]
        return lines.suffix(limit).map { line in
            let message = String(decoding: line, as: UTF8.self)
            let occurrence = occurrences[message, default: 0]
            occurrences[message] = occurrence + 1
            return LogEntry(
                id: "\(message.hashValue)-\(occurrence)",
                level: logLevel(in: message),
                message: message
            )
        }
    }

    public func logStream(level: String = "info") throws -> AsyncThrowingStream<LogEntry, Error> {
        let status = try stateStore.load()
        return MihomoControllerClient(endpoint: status.endpoint).logStream(level: level)
    }

    public func trafficStream() throws -> AsyncThrowingStream<TrafficSnapshot, Error> {
        let status = try stateStore.load()
        return MihomoControllerClient(endpoint: status.endpoint).trafficStream()
    }

    public func memoryStream() throws -> AsyncThrowingStream<MemorySnapshot, Error> {
        let status = try stateStore.load()
        return MihomoControllerClient(endpoint: status.endpoint).memoryStream()
    }

    public func runtimeEvents(limit: Int = 200) throws -> [RuntimeEventEntry] {
        try supervisor.recentRuntimeEvents(limit: limit)
    }

    @discardableResult
    public func setSystemProxy(_ isEnabled: Bool, dryRun: Bool = false) async throws -> [ShellCommand] {
        if !dryRun, let client = privilegedServiceClient() {
            _ = try client.send(client.setSystemProxyEnabledRequest(isEnabled))
            return []
        }
        let status = try stateStore.load()
        let settings = try effectiveSystemProxySettings(for: status)
        return try await systemProxyController.setEnabled(
            isEnabled,
            configuration: SystemProxyConfiguration(
                networkService: settings.networkService,
                host: settings.host,
                port: settings.port,
                bypassList: settings.bypassList,
                mode: settings.mode,
                pacScript: settings.pacScript
            ),
            dryRun: dryRun
        )
    }

    public func availableNetworkServices() throws -> [String] {
        try systemProxyController.availableNetworkServices()
    }

    public func activeNetworkService() throws -> String {
        try systemProxyController.activeNetworkService()
    }

    public func updateSystemProxySettings(_ settings: SystemProxySettings) throws {
        var status = try stateStore.load()
        status.systemProxySettings = settings
        try stateStore.save(status)
    }

    public func serviceModeStatus() -> ServiceModeStatus {
        let status = serviceManager.status()
        persistServiceStatus(status)
        return status
    }

    @discardableResult
    public func installServiceMode() throws -> ServiceModeStatus {
        let status = try serviceManager.installService()
        persistServiceStatus(status)
        return status
    }

    @discardableResult
    public func uninstallServiceMode() throws -> ServiceModeStatus {
        let status = try serviceManager.uninstallService()
        persistServiceStatus(status)
        return status
    }

    public func tunStatus() throws -> TunStatus {
        if let client = privilegedServiceClient() {
            return try client.sendDecodable(client.tunStatusRequest(), as: TunStatus.self)
        }
        let status = try stateStore.load()
        let service = currentServiceStatus()
        let settings = status.runtimeSettings?.tun ?? TunSettings()
        let logPermissionError = recentTunPermissionError()
        return TunStatus(
            isEnabled: settings.isEnabled,
            isRunning: status.state == .running && settings.isEnabled && service.canManageTun,
            requiresService: !service.canManageTun,
            lastError: status.tunStatus?.lastError ?? logPermissionError
        )
    }

    public func dnsSettings() throws -> DnsSettings {
        let status = try stateStore.load()
        return status.runtimeSettings?.dns ?? DnsSettings()
    }

    public func updateDnsSettings(_ settings: DnsSettings) throws {
        var status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        runtimeSettings.dns = settings
        status.runtimeSettings = runtimeSettings
        try stateStore.save(status)
    }

    @discardableResult
    public func applyDnsSettings(_ settings: DnsSettings) async throws -> DnsSettings {
        let normalizedSettings = normalizedDnsSettings(settings)
        try updateDnsSettings(normalizedSettings)

        let status = try stateStore.load()
        if status.state == .running {
            _ = try restart()
            try await waitForControllerReady()
        }

        return normalizedSettings
    }

    @discardableResult
    public func setDnsEnabled(_ isEnabled: Bool) async throws -> DnsSettings {
        var status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        var dns = runtimeSettings.dns ?? DnsSettings()
        dns.isEnabled = isEnabled
        runtimeSettings.dns = dns
        status.runtimeSettings = runtimeSettings
        try stateStore.save(status)

        if status.state == .running {
            _ = try restart()
            try await waitForControllerReady()
        }

        return dns
    }

    public func snifferSettings() throws -> SnifferSettings {
        let status = try stateStore.load()
        return status.runtimeSettings?.sniffer ?? SnifferSettings()
    }

    public func updateSnifferSettings(_ settings: SnifferSettings) throws {
        var status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        runtimeSettings.sniffer = settings
        status.runtimeSettings = runtimeSettings
        try stateStore.save(status)
    }

    @discardableResult
    public func applySnifferSettings(_ settings: SnifferSettings) async throws -> SnifferSettings {
        let normalizedSettings = normalizedSnifferSettings(settings)
        try updateSnifferSettings(normalizedSettings)

        let status = try stateStore.load()
        if status.state == .running {
            _ = try restart()
            try await waitForControllerReady()
        }

        return normalizedSettings
    }

    @discardableResult
    public func setSnifferEnabled(_ isEnabled: Bool) async throws -> SnifferSettings {
        var status = try stateStore.load()
        var runtimeSettings = self.runtimeSettings(for: status)
        var sniffer = runtimeSettings.sniffer ?? SnifferSettings()
        sniffer.isEnabled = isEnabled
        runtimeSettings.sniffer = sniffer
        status.runtimeSettings = runtimeSettings
        try stateStore.save(status)

        if status.state == .running {
            _ = try restart()
            try await waitForControllerReady()
        }

        return sniffer
    }

    public func updateTunSettings(_ settings: TunSettings) throws {
        var status = try stateStore.load()
        var runtimeSettings = runtimeSettings(for: status)
        runtimeSettings.tun = settings
        status.runtimeSettings = runtimeSettings
        status.tunStatus = TunStatus(
            isEnabled: settings.isEnabled,
            isRunning: status.state == .running && settings.isEnabled && serviceManager.status().canManageTun,
            requiresService: !serviceManager.status().canManageTun,
            lastError: status.tunStatus?.lastError
        )
        try stateStore.save(status)
    }

    /// Applies full TUN settings through `updateTunSettingsFlow`, which also
    /// performs tier ownership handoffs when the TUN state transitions.
    @discardableResult
    public func applyTunSettings(_ settings: TunSettings) async throws -> TunStatus {
        try await updateTunSettingsFlow(settings)
    }

    /// Toggles TUN through `updateTunSettingsFlow`, preserving every other
    /// stored TUN setting.
    @discardableResult
    public func setTunEnabled(_ isEnabled: Bool) async throws -> TunStatus {
        let status = try stateStore.load()
        var tun = runtimeSettings(for: status).tun ?? TunSettings()
        tun.isEnabled = isEnabled
        return try await updateTunSettingsFlow(tun)
    }

    public func subStoreStatus() throws -> SubStoreStatus {
        try subStoreManager.status()
    }

    public func updateSubStoreStatus(_ status: SubStoreStatus) throws {
        try subStoreManager.updateStatus(status)
    }

    @discardableResult
    public func prepareSubStoreResources() throws -> SubStoreStatus {
        try subStoreManager.prepareResources()
    }

    public func subStoreRuntimeStatus() async throws -> SubStoreRuntimeStatus {
        let status = try subStoreManager.status()
        let backendURL = subStoreManager.backendURL(for: status)
        return SubStoreRuntimeStatus(
            configuration: status,
            isBackendRunning: await subStoreSupervisor.isRunning,
            backendPID: await subStoreSupervisor.pid,
            backendURL: backendURL,
            resourceVersion: status.installedResourceVersion,
            resourcesInstalled: subStoreManager.resourcesInstalled()
        )
    }

    @discardableResult
    public func setSubStoreEnabled(_ isEnabled: Bool) async throws -> SubStoreStatus {
        var status = try subStoreManager.markEnabled(isEnabled)
        if isEnabled {
            status = try await startSubStoreServices(status: status)
        } else {
            await subStoreSupervisor.stop()
        }
        return status
    }

    public func restartSubStoreService() async throws {
        let status = try subStoreManager.status()
        _ = try await startSubStoreServices(status: status, restartBackend: true)
    }

    public func stopSubStoreService() async {
        await subStoreSupervisor.stop()
    }

    public func subStoreServiceIsRunning() async -> Bool {
        await subStoreSupervisor.isRunning
    }

    public func subStoreLaunchPlan() throws -> SubStoreLaunchPlan {
        try subStoreManager.launchPlan(for: subStoreManager.status(), mixedPort: try? status().proxyPorts.mixedPort)
    }

    @discardableResult
    public func downloadSubStoreBundle(kind: SubStoreBundleKind, from url: URL) async throws -> SubStoreStatus {
        throw KumoError.invalidArguments("Sub-Store resources are bundled with Kumo. Update Kumo to update Sub-Store.")
    }

    /// Returns a configured `SubStoreClient` pointing at whichever backend is
    /// currently active (bundled Node sidecar or custom backend URL). Raises
    /// when no backend is reachable so callers can surface a clear error.
    public func subStoreClient() throws -> SubStoreClient {
        guard let backendURL = subStoreManager.backendURL(for: try subStoreManager.status()) else {
            throw KumoError.invalidArguments("Sub-Store backend is not configured.")
        }
        return SubStoreClient(baseURL: backendURL)
    }

    public func subStoreSubscriptions() async throws -> [SubStoreSubscription] {
        try await subStoreClient().subscriptions()
    }

    public func subStoreCollections() async throws -> [SubStoreCollection] {
        try await subStoreClient().collections()
    }

    public func subStoreEntries(kind: SubStoreEntryKind) async throws -> [SubStoreEntry] {
        let client = try subStoreClient()
        switch kind {
        case .subscription:
            return try await client.subscriptions().map {
                SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: $0.tag ?? [], kind: .subscription)
            }
        case .collection:
            return try await client.collections().map {
                SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: [], kind: .collection)
            }
        }
    }

    @discardableResult
    public func importSubStoreProfile(path subStorePath: String, name: String? = nil, useProxy: Bool = false) async throws -> ProfileSummary {
        let url = try subStoreProfileDownloadURL(path: subStorePath, useProxy: useProxy)
        return try await profileRepository.saveSubStoreProfile(
            name: name ?? subStoreDisplayName(for: subStorePath),
            subStorePath: subStorePath,
            downloadURL: url,
            useProxy: useProxy
        )
    }

    @discardableResult
    public func refreshSubStoreProfile(id: String) async throws -> ProfileSummary {
        let profile = try profileRepository.listProfiles().first { $0.id == id }
        guard let profile, profile.isSubStoreManaged, let subStorePath = profile.subStorePath else {
            throw KumoError.invalidArguments("This profile is not managed by Sub-Store.")
        }
        let url = try subStoreProfileDownloadURL(path: subStorePath, useProxy: profile.useProxy)
        return try await profileRepository.saveSubStoreProfile(
            name: profile.name,
            subStorePath: subStorePath,
            downloadURL: url,
            autoUpdate: profile.autoUpdate,
            useProxy: profile.useProxy,
            preferredID: id,
            makeCurrent: false
        )
    }

    @discardableResult
    public func exportBackup(to destination: URL) throws -> KumoBackupResult {
        try backupManager.exportBackup(to: destination)
    }

    @discardableResult
    public func importBackup(from source: URL) throws -> KumoBackupManifest {
        try backupManager.importBackup(from: source)
    }

    public func checkAppUpdate(
        manifestURL: URL?,
        currentVersion: String,
        channel: AppUpdateChannel = .stable
    ) async throws -> AppUpdateCheckResult {
        try await appUpdateManager.checkForUpdate(
            manifestURL: manifestURL,
            currentVersion: currentVersion,
            channel: channel
        )
    }

    public func downloadAppUpdate(
        manifest: AppUpdateManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppUpdateDownloadResult {
        try await appUpdateManager.downloadUpdate(
            manifest: manifest,
            to: paths.appUpdateDownloadsDirectory,
            progress: progress
        )
    }

    public func installAppUpdate(
        dmgURL: URL,
        currentAppURL: URL,
        processID: Int32
    ) throws {
        try appUpdateInstaller.installDMG(
            dmgURL: dmgURL,
            currentAppURL: currentAppURL,
            processID: processID
        )
    }

    public func userPreferences() -> UserPreferences {
        preferencesStore.load()
    }

    public func updateUserPreferences(_ preferences: UserPreferences) throws {
        try preferencesStore.save(preferences)
    }

    /// Reports the on-disk state of the `kumo` CLI symlink. Always cheap; the
    /// shipping app calls this on every onboarding refresh and in Settings.
    public func cliLinkStatus() -> CLILinkStatus {
        CLILinkInstaller().status()
    }

    /// Creates the `kumo` CLI symlink at the default PATH location. Surfaces a
    /// macOS administrator authorization prompt when the target directory
    /// requires elevated privileges (the default `/usr/local/bin` does).
    @discardableResult
    public func installCLILink() throws -> CLILinkStatus {
        try CLILinkInstaller().install()
    }

    /// Removes the `kumo` CLI symlink. Refuses to delete a symlink that is not
    /// managed by Kumo to avoid removing a user-installed CLI shim.
    @discardableResult
    public func uninstallCLILink() throws -> CLILinkStatus {
        try CLILinkInstaller().uninstall()
    }

}
