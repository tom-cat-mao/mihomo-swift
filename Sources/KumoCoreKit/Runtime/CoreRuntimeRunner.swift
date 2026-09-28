import Foundation

/// Serial executor for `KumoController` work.
///
/// `KumoController` is a synchronous `Sendable` struct: every one of its
/// methods blocks its caller on file IO, helper-IPC sockets, `networksetup`
/// or Yams parsing. The macOS app used to call those methods directly from
/// `@MainActor` code (or, worse, from `@MainActor` code that awaited a
/// `nonisolated async` method, which is unconstrained thread-wise), so every
/// status refresh, proxy reload, log snapshot and TUN probe stalled the main
/// thread.
///
/// This actor owns a single controller instance and exposes the exact subset
/// of its API the app uses, as `async` methods. Awaiting a method here means
/// "run this controller call on the actor's executor" — off the main actor,
/// serialized with every other runner call, and in dispatch order. It is
/// deliberately not `Task.detached` per call: ordering between consecutive
/// controller operations matters (write state, then read it back).
///
/// The CLI (`KumoCLIKit`) and the privileged helper (`KumoService`) keep
/// calling `KumoController` synchronously on their own threads; see
/// `docs/core/control-layer.md`.
public actor CoreRuntimeRunner {
    private let controller: KumoController

    /// Paths for the underlying controller. `KumoPaths` is an immutable value
    /// type, so the app can read it without hopping onto the actor.
    public nonisolated let paths: KumoPaths

    public init(controller: KumoController = KumoController()) {
        self.controller = controller
        self.paths = controller.paths
    }

    // MARK: - Status & core lifecycle

    public func status() throws -> CoreStatus {
        try controller.status()
    }

    public func coreCandidates() throws -> [CoreCandidate] {
        try controller.coreCandidates()
    }

    public func setCorePath(_ path: String) throws {
        try controller.setCorePath(path)
    }

    public func clearCorePath() throws {
        try controller.clearCorePath()
    }

    @discardableResult
    public func installManagedCore() async throws -> CoreInstallResult {
        try await controller.installManagedCore()
    }

    @discardableResult
    public func start(corePath: String? = nil) throws -> CoreStatus {
        try controller.start(corePath: corePath)
    }

    @discardableResult
    public func stop() throws -> CoreStatus {
        try controller.stop()
    }

    @discardableResult
    public func restart(corePath: String? = nil) throws -> CoreStatus {
        try controller.restart(corePath: corePath)
    }

    @discardableResult
    public func shutdownActiveRuntime() async -> ShutdownResult {
        await controller.shutdownActiveRuntime()
    }

    public func waitForControllerReady(
        maxAttempts: Int = 30,
        intervalNanoseconds: UInt64 = 200_000_000
    ) async throws {
        try await controller.waitForControllerReady(
            maxAttempts: maxAttempts,
            intervalNanoseconds: intervalNanoseconds
        )
    }

    // MARK: - Profiles

    public func profiles() throws -> [ProfileSummary] {
        try controller.profiles()
    }

    public func currentProfile() throws -> ProfileSummary {
        try controller.currentProfile()
    }

    public func setCurrentProfile(id: String) throws {
        try controller.setCurrentProfile(id: id)
    }

    public func profileContent(id: String) throws -> String {
        try controller.profileContent(id: id)
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
        try controller.updateProfile(
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
        try controller.deleteProfile(id: id)
    }

    @discardableResult
    public func refreshProfile(id: String) async throws -> ProfileSummary {
        try await controller.refreshProfile(id: id)
    }

    @discardableResult
    public func refreshProfile(from url: URL, useProxy: Bool = false) async throws -> Profile {
        try await controller.refreshProfile(from: url, useProxy: useProxy)
    }

    public func importProfile(from url: URL) throws -> ProfileSummary {
        try controller.importProfile(from: url)
    }

    // MARK: - Runtime settings

    public func setMode(_ mode: OutboundMode) async throws {
        try await controller.setMode(mode)
    }

    public func updateRuntimeSettings(_ settings: CoreRuntimeSettings) async throws {
        try await controller.updateRuntimeSettings(settings)
    }

    public func setControllerSecret(_ secret: String) throws {
        try controller.setControllerSecret(secret)
    }

    public func coreConfiguration() async throws -> CoreConfigurationSnapshot {
        try await controller.coreConfiguration()
    }

    // MARK: - Proxies, rules, connections

    public func proxyGroups() async throws -> [ProxyGroup] {
        try await controller.proxyGroups()
    }

    public func selectProxy(group: String, name: String) async throws {
        try await controller.selectProxy(group: group, name: name)
    }

    public func testGroupDelay(group: ProxyGroup) async throws -> [ProxyNode] {
        try await controller.testGroupDelay(group: group)
    }

    public func rules() async throws -> [RuleEntry] {
        try await controller.rules()
    }

    public func setRuleEnabled(index: Int, isEnabled: Bool) async throws {
        try await controller.setRuleEnabled(index: index, isEnabled: isEnabled)
    }

    public func connections() async throws -> [ConnectionEntry] {
        try await controller.connections()
    }

    public func closeConnection(id: String) async throws {
        try await controller.closeConnection(id: id)
    }

    public func closeConnections(matchingProxy proxy: String? = nil) async throws {
        try await controller.closeConnections(matchingProxy: proxy)
    }

    public func proxyProviders() async throws -> [ProxyProviderEntry] {
        try await controller.proxyProviders()
    }

    public func updateProxyProvider(name: String) async throws {
        try await controller.updateProxyProvider(name: name)
    }

    public func ruleProviders() async throws -> [RuleProviderEntry] {
        try await controller.ruleProviders()
    }

    public func updateRuleProvider(name: String) async throws {
        try await controller.updateRuleProvider(name: name)
    }

    public func upgradeGeoData() async throws {
        try await controller.upgradeGeoData()
    }

    // MARK: - Logs & streams

    public func recentLogs(limit: Int = 300) throws -> [LogEntry] {
        try controller.recentLogs(limit: limit)
    }

    public func logStream(level: String = "info") throws -> AsyncThrowingStream<LogEntry, Error> {
        try controller.logStream(level: level)
    }

    public func trafficStream() throws -> AsyncThrowingStream<TrafficSnapshot, Error> {
        try controller.trafficStream()
    }

    // MARK: - Overrides

    public func overrides() throws -> [OverrideItem] {
        try controller.overrides()
    }

    public func overrideContent(id: String) throws -> String {
        try controller.overrideContent(id: id)
    }

    @discardableResult
    public func addLocalOverride(
        name: String,
        format: OverrideFormat,
        content: String,
        isGlobal: Bool = false
    ) throws -> OverrideItem {
        try controller.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
    }

    @discardableResult
    public func addRemoteOverride(
        url: URL,
        name: String? = nil,
        format: OverrideFormat = .yaml,
        fingerprint: String? = nil,
        isGlobal: Bool = false
    ) async throws -> OverrideItem {
        try await controller.addRemoteOverride(
            url: url,
            name: name,
            format: format,
            fingerprint: fingerprint,
            isGlobal: isGlobal
        )
    }

    public func updateOverride(_ item: OverrideItem, content: String? = nil) throws {
        try controller.updateOverride(item, content: content)
    }

    public func deleteOverride(id: String) throws {
        try controller.deleteOverride(id: id)
    }

    // MARK: - System proxy & service mode

    @discardableResult
    public func setSystemProxy(_ isEnabled: Bool, dryRun: Bool = false) async throws -> [ShellCommand] {
        try await controller.setSystemProxy(isEnabled, dryRun: dryRun)
    }

    public func updateSystemProxySettings(_ settings: SystemProxySettings) throws {
        try controller.updateSystemProxySettings(settings)
    }

    public func serviceModeStatus() -> ServiceModeStatus {
        controller.serviceModeStatus()
    }

    @discardableResult
    public func installServiceMode() throws -> ServiceModeStatus {
        try controller.installServiceMode()
    }

    @discardableResult
    public func uninstallServiceMode() throws -> ServiceModeStatus {
        try controller.uninstallServiceMode()
    }

    // MARK: - TUN / DNS / Sniffer

    public func tunStatus() throws -> TunStatus {
        try controller.tunStatus()
    }

    public func updateTunSettings(_ settings: TunSettings) throws {
        try controller.updateTunSettings(settings)
    }

    @discardableResult
    public func applyTunSettings(_ settings: TunSettings) async throws -> TunStatus {
        try await controller.applyTunSettings(settings)
    }

    @discardableResult
    public func setTunEnabled(_ isEnabled: Bool) async throws -> TunStatus {
        try await controller.setTunEnabled(isEnabled)
    }

    @discardableResult
    public func applyDnsSettings(_ settings: DnsSettings) async throws -> DnsSettings {
        try await controller.applyDnsSettings(settings)
    }

    @discardableResult
    public func setDnsEnabled(_ isEnabled: Bool) async throws -> DnsSettings {
        try await controller.setDnsEnabled(isEnabled)
    }

    @discardableResult
    public func applySnifferSettings(_ settings: SnifferSettings) async throws -> SnifferSettings {
        try await controller.applySnifferSettings(settings)
    }

    @discardableResult
    public func setSnifferEnabled(_ isEnabled: Bool) async throws -> SnifferSettings {
        try await controller.setSnifferEnabled(isEnabled)
    }

    // MARK: - Sub-Store

    public func subStoreStatus() throws -> SubStoreStatus {
        try controller.subStoreStatus()
    }

    public func updateSubStoreStatus(_ status: SubStoreStatus) throws {
        try controller.updateSubStoreStatus(status)
    }

    @discardableResult
    public func prepareSubStoreResources() throws -> SubStoreStatus {
        try controller.prepareSubStoreResources()
    }

    public func subStoreRuntimeStatus() async throws -> SubStoreRuntimeStatus {
        try await controller.subStoreRuntimeStatus()
    }

    @discardableResult
    public func setSubStoreEnabled(_ isEnabled: Bool) async throws -> SubStoreStatus {
        try await controller.setSubStoreEnabled(isEnabled)
    }

    public func restartSubStoreService() async throws {
        try await controller.restartSubStoreService()
    }

    public func stopSubStoreService() async {
        await controller.stopSubStoreService()
    }

    public func subStoreEntries(kind: SubStoreEntryKind) async throws -> [SubStoreEntry] {
        try await controller.subStoreEntries(kind: kind)
    }

    @discardableResult
    public func importSubStoreProfile(
        path: String,
        name: String?,
        useProxy: Bool
    ) async throws -> ProfileSummary {
        try await controller.importSubStoreProfile(path: path, name: name, useProxy: useProxy)
    }

    @discardableResult
    public func downloadSubStoreBundle(kind: SubStoreBundleKind, from url: URL) async throws -> SubStoreStatus {
        try await controller.downloadSubStoreBundle(kind: kind, from: url)
    }

    // MARK: - App updates

    public func checkAppUpdate(
        manifestURL: URL?,
        currentVersion: String,
        channel: AppUpdateChannel = .stable
    ) async throws -> AppUpdateCheckResult {
        try await controller.checkAppUpdate(
            manifestURL: manifestURL,
            currentVersion: currentVersion,
            channel: channel
        )
    }

    public func downloadAppUpdate(
        manifest: AppUpdateManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AppUpdateDownloadResult {
        try await controller.downloadAppUpdate(manifest: manifest, progress: progress)
    }

    public func installAppUpdate(dmgURL: URL, currentAppURL: URL, processID: Int32) throws {
        try controller.installAppUpdate(dmgURL: dmgURL, currentAppURL: currentAppURL, processID: processID)
    }

    // MARK: - Preferences

    public func userPreferences() -> UserPreferences {
        controller.userPreferences()
    }

    public func updateUserPreferences(_ preferences: UserPreferences) throws {
        try controller.updateUserPreferences(preferences)
    }

    // MARK: - CLI link

    public func cliLinkStatus() -> CLILinkStatus {
        controller.cliLinkStatus()
    }

    @discardableResult
    public func installCLILink() throws -> CLILinkStatus {
        try controller.installCLILink()
    }

    @discardableResult
    public func uninstallCLILink() throws -> CLILinkStatus {
        try controller.uninstallCLILink()
    }
}
