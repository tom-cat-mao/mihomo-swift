import AppKit
import Foundation
import Observation
import KumoCoreKit

struct ProxyGroupDelaySummary: Equatable {
    var totalCount: Int
    var successCount: Int
    var timeoutCount: Int
    var missingCount: Int
    var errorCount: Int
    var details: [String]
    var requestFailed: Bool

    init(nodes: [ProxyNode]) {
        totalCount = nodes.count
        successCount = nodes.count { $0.delayStatus == .success }
        timeoutCount = nodes.count { $0.delayStatus == .timeout }
        missingCount = nodes.count { $0.delayStatus == .missing }
        errorCount = nodes.count { $0.delayStatus == .error }
        details = nodes.compactMap { node in
            guard node.delayStatus == .error, let error = node.delayError else { return nil }
            return "\(node.name): \(error)"
        }
        requestFailed = false
    }

    init(requestError: String) {
        totalCount = 0
        successCount = 0
        timeoutCount = 0
        missingCount = 0
        errorCount = 0
        details = [requestError]
        requestFailed = true
    }

    var text: String {
        if requestFailed { return String(localized: "Delay test failed") }
        var parts = [String(format: String(localized: "%1$d/%2$d succeeded"), successCount, totalCount)]
        if timeoutCount > 0 {
            parts.append(String(format: String(localized: "%1$d timeout"), timeoutCount))
        }
        if missingCount > 0 {
            parts.append(String(format: String(localized: "%1$d missing"), missingCount))
        }
        if errorCount > 0 {
            parts.append(String(format: String(localized: "%1$d error"), errorCount))
        }
        return parts.joined(separator: " · ")
    }

    var hasFailures: Bool {
        requestFailed || timeoutCount > 0 || missingCount > 0 || errorCount > 0
    }
}

/// Turns persisted exit records into at-most-once UI notifications. The first
/// observation is only a baseline: an exit recorded before this GUI launched
/// must not be presented as a new crash. Expected stops update the baseline but
/// never produce an alert.
struct CoreExitObservation {
    private var lastExit: CoreExit?
    private var hasBaseline = false

    mutating func observe(_ exit: CoreExit?) -> CoreExit? {
        let previousExit = lastExit
        defer {
            lastExit = exit
            hasBaseline = true
        }
        guard hasBaseline, let exit, !exit.expected, exit != previousExit else {
            return nil
        }
        return exit
    }
}

@MainActor
@Observable
final class KumoAppStore {
    var status = CoreStatus()
    var proxyGroups: [ProxyGroup] = []
    /// Read-only proxy groups parsed from the current profile YAML, used as
    /// a fallback render source for the Overview sidebar while the core is
    /// stopped. Refreshed alongside `refreshProfiles()` and after every
    /// `loadProxyGroups()` call so the preview is always current.
    var profilePreviewGroups: [ProxyGroup] = []
    var profiles: [ProfileSummary] = []
    var currentProfile: ProfileSummary?
    var currentProfileDeclaresDNS = false
    var coreConfiguration = CoreConfigurationSnapshot()
    var trafficSnapshot = TrafficSnapshot()
    /// Rolling 60-sample buffer of throughput data points (~60 s at
    /// mihomo's 1 Hz `/traffic` stream). Used by the Overview Traffic card
    /// to render a sparkline when expanded. Reset whenever the core stops
    /// or the stream errors out.
    var trafficHistory: [TrafficSample] = []
    var rules: [RuleEntry] = []
    var topology: TopologyGraph?
    var connections: [ConnectionEntry] = []
    var logs: [LogEntry] = []
    var proxyProviders: [ProxyProviderEntry] = []
    var ruleProviders: [RuleProviderEntry] = []
    var overrides: [OverrideItem] = []
    var subStoreStatus = SubStoreStatus()
    var subStoreRuntimeStatus = SubStoreRuntimeStatus()
    var subStoreEntries: [SubStoreEntry] = []
    var serviceModeStatus = ServiceModeStatus()
    /// Status of the user-level LaunchAgent tier (`kumod`), shown in
    /// Settings → General → Background. Distinct from `serviceModeStatus`,
    /// which describes the privileged root helper.
    var agentStatus = ServiceModeStatus()
    var tunStatus = TunStatus()
    var coreCandidates: [CoreCandidate] = []
    var preferences = UserPreferences()
    /// Reference to the localization manager so `loadPreferences()` can sync
    /// the language preference when it is refreshed from disk.
    var localizationManager: LocalizationManager?
    /// Drives the first-run onboarding sheet attached at the root view.
    /// `loadPreferences()` flips this on when `preferences.hasCompletedOnboarding`
    /// is false; `completeOnboarding()` and `reopenOnboarding()` are the only
    /// authorized state transitions.
    var showOnboarding = false
    var errorMessage: String?
    /// Start failures that can be resolved only after explicit user approval.
    var portConflicts: [PortConflict] = []
    var profileUpdateStatusMessage: String?
    var profileUpdateStatusIsFailure = false
    var refreshingProfileIDs: Set<String> = []
    var isLoading = false
    var isSwitchingMode = false
    var isImportingProfile = false
    var isInstallingCore = false
    var isTestingDelay = false
    /// Last completed delay-test outcome per group. A refresh of `/proxies`
    /// clears these summaries because its history values are stale snapshots.
    private(set) var delayTestSummaries: [String: ProxyGroupDelaySummary] = [:]
    var isStreamingLogs = false
    var isCheckingForUpdates = false
    var isDownloadingUpdate = false
    var isInstallingUpdate = false
    var updateDownloadProgress: Double?
    var updateStatusMessage: String?
    var lastUpdateCheckResult: AppUpdateCheckResult?
    private(set) var externalChangeRevision = 0
    private(set) var externalDomainRevisions: [ControlPlaneChangeDomain: Int] = [:]

    /// Synchronous escape hatch for bootstrap callers that cannot await:
    /// `KumoApp.init` reads the persisted preferences before the first frame,
    /// and `SubStoreStore` receives a controller to build its client. Every
    /// other controller call in this store goes through `runner` so the file
    /// IO, helper IPC and Yams parsing stay off the main thread. Injectable so
    /// tests can run the store against a hermetic app-support directory.
    let controller: KumoController
    /// Serial executor for all controller work this store performs.
    private let runner: CoreRuntimeRunner
    /// Resolved on demand rather than at store construction: constructing the
    /// store must not touch `UserNotifications`, whose center is unavailable
    /// in non-app processes (SwiftPM test bundles) and would throw there.
    private var appNotificationCoordinator: AppNotificationCoordinator { .shared }
    private let proxyGeoLookup: ProxyGeoLookup
    private static let updatePollingIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000
    private static let profileUpdatePollingIntervalNanoseconds: UInt64 = 60 * 1_000_000_000
    private static let systemProxyPollingIntervalNanoseconds: UInt64 = 5 * 1_000_000_000
    private var loadingTaskCount = 0
    private var trafficStreamTask: Task<Void, Never>?
    private var logStreamTask: Task<Void, Never>?
    private var lastNotifiedDownloadBucket: Int?
    private var proxyGeoTask: Task<Void, Never>?
    private var updatePollingTask: Task<Void, Never>?
    private var profileUpdatePollingTask: Task<Void, Never>?
    private var systemProxyPollingTask: Task<Void, Never>?
    private var controlPlaneDebounceTask: Task<Void, Never>?
    private var pendingControlPlaneDomains: Set<ControlPlaneChangeDomain> = []
    private var controlPlaneDebounceNanoseconds: UInt64 = 200_000_000
    @ObservationIgnored
    nonisolated(unsafe) private var controlPlaneObserverToken: NSObjectProtocol?
    private var isPollingForUpdates = false
    private var lastProfileRefreshFailureNotifications: [String: Date] = [:]
    private var coreExitObservation = CoreExitObservation()
    /// One-shot gate for the post-update agent repair in `refreshAll()`:
    /// launch must repair at most once, and manual refreshes must not re-run
    /// launchctl churn.
    private var didAttemptAgentUpdateRepair = false

    private enum AppUpdateCheckSource {
        case manual
        case polling
    }

    private enum ProfileRefreshSource {
        case manual
        case automatic
    }

    init(controller: KumoController = KumoController()) {
        self.controller = controller
        let runner = CoreRuntimeRunner(controller: controller)
        self.runner = runner
        self.proxyGeoLookup = ProxyGeoLookup(cacheURL: runner.paths.proxyGeoCacheFile)
    }

    deinit {
        if let controlPlaneObserverToken {
            ControlPlaneNotifier.shared.removeObserver(controlPlaneObserverToken)
        }
    }

    func refreshAll() async {
        await refreshStatus()
        syncTrafficStreamWithStatus()
        await refreshProfiles()
        await refreshDueProfiles()
        await refreshCoreCandidates()
        await refreshProfiles()
        await loadPreferences()
        await refreshSystemProxyStatus()
        await loadProxyGroups()
        await loadCoreConfiguration()
        await loadTopology()
        await loadInspectData()
        await loadResources()
        await refreshOverrides()
        await refreshSubStoreRuntimeStatus()
        await refreshServiceModeStatus()
        await refreshAgentStatus()
        await repairInstalledAgentAfterAppUpdate()
        await refreshTunStatus()
    }

    func refreshStatus() async {
        do {
            let refreshed = try await runner.status()
            status = refreshed
            if let exit = coreExitObservation.observe(refreshed.lastExit) {
                errorMessage = exit.message
                appNotificationCoordinator.postCoreUnexpectedExit(error: exit.message)
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    var systemProxyStatus: SystemProxyStatus {
        SystemProxyStatus(status: status)
    }

    func refreshSystemProxyStatus() async {
        do {
            let proxy = try await runner.systemProxyStatus()
            status.systemProxyEnabled = proxy.enabled
            status.systemProxyOwnership = proxy.ownership
            status.systemProxyApplied = proxy.applied
            status.systemProxySettings = proxy.settings
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func refreshCoreCandidates() async {
        do {
            coreCandidates = try await runner.coreCandidates()
            if !coreCandidates.isEmpty {
                errorMessage = nil
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func setCorePath(_ path: String) async {
        do {
            try await runner.setCorePath(path)
            await refreshStatus()
            await refreshCoreCandidates()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func clearCorePath() async {
        do {
            try await runner.clearCorePath()
            await refreshStatus()
            await refreshCoreCandidates()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func installManagedCore() async {
        guard !isInstallingCore else { return }

        isInstallingCore = true
        defer { isInstallingCore = false }

        await performLoadingTask { [self] in
            let wasRunning = self.status.state == .running
            let result = try await self.runner.installManagedCore()
            await self.refreshCoreCandidates()

            if wasRunning {
                self.status = try await self.runner.restart()
                try await self.runner.waitForControllerReady()
                await self.loadProxyGroups()
                await self.loadCoreConfiguration()
            } else {
                await self.refreshStatus()
            }

            self.status.message = "Installed Mihomo core \(result.version)."
        }
    }

    func refreshProfiles() async {
        do {
            profiles = try await runner.profiles()
            currentProfile = try await runner.currentProfile()
            currentProfileDeclaresDNS = try await runner.currentProfileDeclaresDNS()
            errorMessage = nil
        } catch {
            currentProfileDeclaresDNS = false
            errorMessage = displayMessage(for: error)
        }
        await refreshProfilePreview()
    }

    func startCore(resolvePortConflicts: Bool = false) async {
        beginLoading()
        defer { endLoading() }
        portConflicts = []

        do {
            let shouldReapplySystemProxy = resolvePortConflicts && status.systemProxyEnabled
            let installResult = try await installManagedCoreIfNeeded()
            status = try await runner.start(resolvePortConflicts: resolvePortConflicts)
            try await runner.waitForControllerReady()
            // Socket tiers reapply inside their start route. Apply here only
            // for the local supervisor so the previous-proxy snapshot is not
            // captured twice.
            if shouldReapplySystemProxy, status.ownerTier == .localSupervisor {
                _ = try await runner.setSystemProxy(true)
            }
            startTrafficStream()
            await refreshProfiles()
            await loadProxyGroups()
            await loadCoreConfiguration()
            await loadTopology()
            await loadResources()
            await refreshOverrides()
            if let installResult {
                status.message = "Installed Mihomo core \(installResult.version) and started."
            }
            errorMessage = nil
            appNotificationCoordinator.clearCoreStateNotifications()
        } catch {
            let message = displayMessage(for: error)
            if case KumoError.portConflicts(let conflicts) = error {
                portConflicts = conflicts
                errorMessage = nil
            } else {
                errorMessage = message
            }
            // Surface the failure as a system notification so users notice
            // it even when the main window is occluded or the menu bar
            // status item isn't visible.
            appNotificationCoordinator.postCoreStartFailed(error: message)
        }
    }

    func dismissPortConflicts() {
        portConflicts = []
    }

    func stopCore() async {
        do {
            stopTrafficStream()
            stopLogStream()
            status = try await runner.stop()
            proxyGroups = []
            rules = []
            connections = []
            proxyProviders = []
            ruleProviders = []
            coreConfiguration = CoreConfigurationSnapshot(mode: status.mode, mixedPort: status.proxyPorts.mixedPort)
            trafficSnapshot = TrafficSnapshot()
            trafficHistory = []
            await loadTopology()
            await refreshServiceModeStatus()
            await refreshTunStatus()
            errorMessage = nil
            appNotificationCoordinator.clearCoreStateNotifications()
        } catch {
            let message = displayMessage(for: error)
            errorMessage = message
            appNotificationCoordinator.postCoreStopFailed(error: message)
        }
    }

    /// Stops this process's runtime children before handing the bundle to the
    /// detached update installer. The install flow ends with
    /// `NSApplication.terminate`, and `KumoAppDelegate.applicationShouldTerminate`
    /// takes the `.terminateNow` fast path while `isInstallingUpdate` is set,
    /// so `prepareForTermination()` never runs there. Without this the
    /// Sub-Store sidecar — a child of the GUI process — is orphaned across
    /// the relaunch.
    func prepareForUpdateInstall() async {
        if status.systemProxyEnabled {
            setSystemProxyEnabled(false)
        }
        if status.state == .running {
            await stopCore()
        }
        await runner.stopSubStoreService()
    }

    func prepareForTermination() async {
        stopUpdatePolling()
        stopProfileUpdatePolling()
        stopSystemProxyPolling()
        stopTrafficStream()
        stopLogStream()
        proxyGeoTask?.cancel()
        proxyGeoTask = nil

        // `keepCoreRunningOnQuit` leaves the core with its owning tier (user
        // agent or root daemon) so it keeps serving after the GUI exits;
        // otherwise the historical stop-and-disable path runs. The Sub-Store
        // sidecar is always a child of this process, so quitting must stop it
        // too — otherwise the orphaned Node process keeps writing the
        // Sub-Store data store and the next launch spawns a second instance
        // on a fresh port. Both legs run concurrently so the quit path waits
        // for max(core shutdown, sidecar stop) rather than their sum; the
        // delegate's 5 s gate still bounds the whole cleanup.
        let policy = preferences.appTerminationPolicy
        async let runtimeShutdown = runner.prepareForAppTermination(policy: policy)
        async let sidecarShutdown: Void = runner.stopSubStoreService()
        let result = await runtimeShutdown
        await sidecarShutdown
        status = result.status
        status.systemProxyEnabled = false
        proxyGroups = []
        rules = []
        connections = []
        proxyProviders = []
        ruleProviders = []
        coreConfiguration = CoreConfigurationSnapshot(mode: status.mode, mixedPort: status.proxyPorts.mixedPort)
        trafficSnapshot = TrafficSnapshot()
        trafficHistory = []
        await refreshServiceModeStatus()
        await refreshTunStatus()
        errorMessage = result.diagnostics.first
    }

    func setMode(_ mode: OutboundMode) async {
        guard mode != status.mode else { return }
        guard !isSwitchingMode else { return }

        let previousStatusMode = status.mode
        let previousConfigurationMode = coreConfiguration.mode
        var didApplyMode = false

        isSwitchingMode = true
        status.mode = mode
        coreConfiguration.mode = mode
        defer { isSwitchingMode = false }

        do {
            try await runner.setMode(mode)
            didApplyMode = true
            errorMessage = nil

            if status.state == .running {
                try await runner.closeConnections(matchingProxy: nil)
                connections = []
                await loadProxyGroups()
            }
            await loadTopology()
        } catch {
            if !didApplyMode {
                status.mode = previousStatusMode
                coreConfiguration.mode = previousConfigurationMode
            }
            errorMessage = displayMessage(for: error)
        }
    }

    func loadProxyGroups() async {
        guard status.state == .running else {
            proxyGroups = []
            delayTestSummaries = [:]
            proxyGeoTask?.cancel()
            proxyGeoTask = nil
            return
        }

        do {
            proxyGroups = try await runner.proxyGroups()
            delayTestSummaries = [:]
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }

        await applyCachedCountries()
        await scheduleCountryDetection()
        await refreshProfilePreview()
    }

    /// Re-parses the current profile YAML into a list of read-only proxy
    /// groups (`profilePreviewGroups`). Used by the Overview sidebar to
    /// render the user's configured nodes while mihomo is stopped. Failures
    /// are intentionally swallowed — there's no actionable error to surface
    /// for a missing or malformed `proxy-groups:` section, and the empty
    /// fallback already provides a clear UI state.
    ///
    /// The parse itself is memoized on the profile file's identity, so the three
    /// passes one `loadProxyGroups()` makes, and the 60 s profile poll, reuse it
    /// until the file changes on disk.
    private func refreshProfilePreview() async {
        guard let profileID = currentProfile?.id else {
            profilePreviewGroups = []
            return
        }
        guard let groups = try? await runner.profileProxyGroups(id: profileID) else {
            profilePreviewGroups = []
            return
        }
        profilePreviewGroups = groups
    }

    /// Reads cached `server → country` codes for every node in the current
    /// `proxyGroups` and writes them onto `detectedCountry` synchronously,
    /// so the UI shows known flags immediately without waiting on the
    /// async lookup task.
    private func applyCachedCountries() async {
        guard let serverMap = await currentProfileServerMap(), !serverMap.isEmpty else {
            return
        }
        Task { @MainActor [proxyGeoLookup] in
            var updates: [String: String] = [:]
            for server in Set(serverMap.values) {
                if let code = await proxyGeoLookup.cachedCountry(for: server) {
                    updates[server] = code
                }
            }
            guard !updates.isEmpty else { return }
            self.writeBackCountries(serverMap: serverMap, codes: updates)
        }
    }

    /// Spawns a single async task that resolves country codes for every
    /// known node server in the current profile, deduplicating across nodes
    /// that share a server and writing the result back to `proxyGroups`.
    /// Re-entrancy is guarded by `proxyGeoTask` — calling this again while
    /// a previous lookup is still in flight cancels the previous task.
    private func scheduleCountryDetection() async {
        proxyGeoTask?.cancel()
        guard let serverMap = await currentProfileServerMap(), !serverMap.isEmpty else {
            return
        }
        let hosts = Array(Set(serverMap.values))
        let lookup = proxyGeoLookup
        proxyGeoTask = Task { @MainActor [weak self] in
            let codes = await lookup.countries(for: hosts)
            guard !Task.isCancelled, let self else { return }
            self.writeBackCountries(serverMap: serverMap, codes: codes)
        }
    }

    private func writeBackCountries(serverMap: [String: String], codes: [String: String]) {
        guard !codes.isEmpty else { return }

        // Resolve the pending writes before touching anything: when no node
        // changed, `proxyGroups` is left completely alone and no observer is
        // notified.
        var pending: [(groupIndex: Int, proxyIndex: Int, code: String)] = []
        for groupIndex in proxyGroups.indices {
            for proxyIndex in proxyGroups[groupIndex].proxies.indices {
                let proxy = proxyGroups[groupIndex].proxies[proxyIndex]
                guard let server = serverMap[proxy.name] else { continue }
                guard let code = codes[server.lowercased()] ?? codes[server] else { continue }
                guard proxy.detectedCountry != code else { continue }
                pending.append((groupIndex, proxyIndex, code))
            }
        }
        guard !pending.isEmpty else { return }

        // Mutate each proxy element in place through its index. The previous
        // `var updated = proxyGroups` + whole-array reassign forced a copy of
        // every group and every proxy just to stamp a country code onto a few.
        for change in pending {
            proxyGroups[change.groupIndex].proxies[change.proxyIndex].detectedCountry = change.code
        }
    }

    private func currentProfileServerMap() async -> [String: String]? {
        guard let profileID = currentProfile?.id else { return nil }
        guard let nodes = try? await runner.profileNodes(id: profileID) else { return nil }
        return nodes.mapValues(\.server)
    }

    func loadCoreConfiguration() async {
        guard status.state == .running else {
            let settings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
            coreConfiguration = CoreConfigurationSnapshot(
                mode: status.mode,
                mixedPort: settings.mixedPort,
                logLevel: settings.logLevel,
                allowLAN: settings.allowLAN,
                ipv6: settings.ipv6,
                geoData: settings.geoData,
                tunEnabled: settings.tun?.isEnabled ?? false,
                dnsEnabled: settings.dns?.isEnabled ?? false,
                snifferEnabled: settings.sniffer?.isEnabled ?? false,
                dns: settings.dns,
                sniffer: settings.sniffer
            )
            return
        }

        do {
            coreConfiguration = try await runner.coreConfiguration()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func loadTopology() async {
        do {
            topology = try await runner.topology()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func loadInspectData() async {
        do {
            logs = try await runner.recentLogs()
        } catch {
            logs = []
        }

        guard status.state == .running else {
            rules = []
            connections = []
            return
        }

        do {
            async let nextRules = runner.rules()
            async let nextConnections = runner.connections()
            rules = try await nextRules
            connections = try await nextConnections
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func loadResources() async {
        guard status.state == .running else {
            proxyProviders = []
            ruleProviders = []
            return
        }

        do {
            async let nextProxyProviders = runner.proxyProviders()
            async let nextRuleProviders = runner.ruleProviders()
            proxyProviders = try await nextProxyProviders
            ruleProviders = try await nextRuleProviders
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func updateRuntimeSettings(_ settings: CoreRuntimeSettings) async {
        await performLoadingTask { [self] in
            try await runner.updateRuntimeSettings(settings)
            status.runtimeSettings = settings
            status.proxyPorts.mixedPort = settings.mixedPort
            if let service = try? await runner.status().serviceModeStatus {
                serviceModeStatus = service
            }
            coreConfiguration.mixedPort = settings.mixedPort
            coreConfiguration.logLevel = settings.logLevel
            coreConfiguration.allowLAN = settings.allowLAN
            coreConfiguration.ipv6 = settings.ipv6
            coreConfiguration.geoData = settings.geoData
            coreConfiguration.tunEnabled = settings.tun?.isEnabled ?? coreConfiguration.tunEnabled
        }
    }

    func setControllerSecret(_ secret: String) async {
        do {
            try await runner.setControllerSecret(secret)
            status.endpoint.secret = secret
            if status.state == .running {
                startTrafficStream()
            }
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func setRuleEnabled(_ rule: RuleEntry, isEnabled: Bool) async {
        await performLoadingTask { [self] in
            try await runner.setRuleEnabled(index: rule.index, isEnabled: isEnabled)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index].isEnabled = isEnabled
            }
        }
    }

    func updateProxyProvider(_ provider: ProxyProviderEntry) async {
        await performLoadingTask { [self] in
            try await runner.updateProxyProvider(name: provider.name)
            await loadResources()
        }
    }

    func updateRuleProvider(_ provider: RuleProviderEntry) async {
        await performLoadingTask { [self] in
            try await runner.updateRuleProvider(name: provider.name)
            await loadResources()
        }
    }

    func updateAllProviders() async {
        await performLoadingTask { [self] in
            for provider in proxyProviders {
                try await runner.updateProxyProvider(name: provider.name)
            }
            for provider in ruleProviders {
                try await runner.updateRuleProvider(name: provider.name)
            }
            await loadResources()
        }
    }

    func upgradeGeoData() async {
        await performLoadingTask { [self] in
            try await runner.upgradeGeoData()
        }
    }

    func selectProxy(group: ProxyGroup, proxy: ProxyNode) async {
        await performLoadingTask { [self] in
            try await self.runner.selectProxy(group: group.name, name: proxy.name)
            await self.loadProxyGroups()
            await self.loadTopology()
        }
    }

    func testDelay(for group: ProxyGroup) async {
        guard !isTestingDelay else { return }
        isTestingDelay = true
        defer { isTestingDelay = false }

        // A new run invalidates the previous run immediately. Historical
        // values may remain visible only as stale, never as fresh successes.
        if let index = proxyGroups.firstIndex(where: { $0.id == group.id }) {
            for nodeIndex in proxyGroups[index].proxies.indices {
                var node = proxyGroups[index].proxies[nodeIndex]
                guard node.delayStatus != .missing else { continue }
                if node.delay != nil {
                    node.delayStatus = .stale
                } else {
                    node.delayStatus = nil
                }
                node.delayError = nil
                proxyGroups[index].proxies[nodeIndex] = node
            }
        }
        delayTestSummaries[group.id] = nil
        errorMessage = nil

        do {
            let nodes = try await runner.testGroupDelay(group: group)
            if let index = proxyGroups.firstIndex(where: { $0.id == group.id }) {
                proxyGroups[index].proxies = nodes
                delayTestSummaries[group.id] = ProxyGroupDelaySummary(nodes: nodes)
            }
        } catch {
            let message = displayMessage(for: error)
            delayTestSummaries[group.id] = ProxyGroupDelaySummary(requestError: message)
            errorMessage = message
        }
    }

    func delayTestSummary(for group: ProxyGroup) -> ProxyGroupDelaySummary? {
        delayTestSummaries[group.id]
    }

    func importRemoteProfile(urlString: String, useProxy: Bool) async {
        guard let url = URL(string: urlString), !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a valid profile URL."
            return
        }

        isImportingProfile = true
        defer { isImportingProfile = false }

        await performLoadingTask { [self] in
            _ = try await runner.refreshProfile(from: url, useProxy: useProxy)
            await refreshProfiles()
            try await activateCurrentProfileAfterImport()
        }
    }

    func importLocalProfile(from url: URL) async {
        await performLoadingTask { [self] in
            _ = try await runner.importProfile(from: url)
            await refreshProfiles()
            try await activateCurrentProfileAfterImport()
        }
    }

    func profileContent(id: String) async -> String? {
        do {
            return try await runner.profileContent(id: id)
        } catch {
            errorMessage = displayMessage(for: error)
            return nil
        }
    }

    func refreshOverrides() async {
        do {
            overrides = try await runner.overrides()
            currentProfileDeclaresDNS = try await runner.currentProfileDeclaresDNS()
            errorMessage = nil
        } catch {
            currentProfileDeclaresDNS = false
            errorMessage = displayMessage(for: error)
        }
    }

    func refreshSubStoreStatus() async {
        do {
            subStoreStatus = try await runner.subStoreStatus()
            subStoreRuntimeStatus.configuration = subStoreStatus
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func refreshSubStoreRuntimeStatus() async {
        do {
            subStoreRuntimeStatus = try await runner.subStoreRuntimeStatus()
            subStoreStatus = subStoreRuntimeStatus.configuration
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func prepareSubStoreResources() async {
        do {
            subStoreStatus = try await runner.prepareSubStoreResources()
            subStoreRuntimeStatus.configuration = subStoreStatus
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func setSubStoreEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            subStoreStatus = try await runner.setSubStoreEnabled(isEnabled)
            subStoreRuntimeStatus = try await runner.subStoreRuntimeStatus()
        }
    }

    func restartSubStoreService() async {
        await performLoadingTask { [self] in
            try await runner.restartSubStoreService()
            subStoreRuntimeStatus = try await runner.subStoreRuntimeStatus()
        }
    }

    func stopSubStoreService() async {
        await runner.stopSubStoreService()
        await refreshSubStoreRuntimeStatus()
    }

    func updateSubStoreStatus(_ status: SubStoreStatus) async {
        do {
            try await runner.updateSubStoreStatus(status)
            subStoreStatus = status
            subStoreRuntimeStatus.configuration = status
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func downloadSubStoreBundle(kind: SubStoreBundleKind, urlString: String) async {
        guard let url = URL(string: urlString) else {
            errorMessage = "Enter a valid Sub-Store bundle URL."
            return
        }

        await performLoadingTask { [self] in
            subStoreStatus = try await runner.downloadSubStoreBundle(kind: kind, from: url)
        }
    }

    func loadSubStoreEntries() async {
        do {
            async let subscriptions = runner.subStoreEntries(kind: .subscription)
            async let collections = runner.subStoreEntries(kind: .collection)
            let loadedSubscriptions = try await subscriptions
            let loadedCollections = try await collections
            subStoreEntries = loadedSubscriptions + loadedCollections
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func importSubStoreProfile(path: String, name: String?, useProxy: Bool) async {
        await performLoadingTask { [self] in
            _ = try await runner.importSubStoreProfile(path: path, name: name, useProxy: useProxy)
            await refreshProfiles()
        }
    }

    func overrideContent(id: String) async -> String? {
        do {
            return try await runner.overrideContent(id: id)
        } catch {
            errorMessage = displayMessage(for: error)
            return nil
        }
    }

    func addLocalOverride(name: String, format: OverrideFormat, content: String, isGlobal: Bool) async {
        do {
            _ = try await runner.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
            await refreshOverrides()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func addRemoteOverride(urlString: String, format: OverrideFormat, isGlobal: Bool) async {
        guard let url = URL(string: urlString) else {
            errorMessage = "Enter a valid override URL."
            return
        }

        await performLoadingTask { [self] in
            _ = try await runner.addRemoteOverride(url: url, format: format, isGlobal: isGlobal)
            await refreshOverrides()
        }
    }

    func updateOverride(_ item: OverrideItem, content: String?) async {
        do {
            try await runner.updateOverride(item, content: content)
            await refreshOverrides()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func deleteOverride(_ item: OverrideItem) async {
        do {
            try await runner.deleteOverride(id: item.id)
            await refreshOverrides()
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func updateProfile(
        id: String,
        name: String,
        remoteURLString: String?,
        autoUpdate: Bool,
        useProxy: Bool,
        rawYAML: String
    ) async {
        await performLoadingTask { [self] in
            let trimmedURL = remoteURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let remoteURL = trimmedURL.isEmpty ? nil : URL(string: trimmedURL)
            if !trimmedURL.isEmpty, remoteURL == nil {
                throw KumoError.invalidArguments("Enter a valid subscription URL.")
            }

            let wasCurrent = self.currentProfile?.id == id
            _ = try await self.runner.updateProfile(
                id: id,
                name: name,
                remoteURL: remoteURL,
                autoUpdate: autoUpdate,
                useProxy: useProxy,
                rawYAML: rawYAML
            )
            await self.refreshProfiles()
            try await self.refreshCurrentProfileAfterTransactionIfNeeded(wasCurrent, message: "Profile updated.")
        }
    }

    func refreshProfile(_ profile: ProfileSummary) async {
        guard beginProfileRefresh(profile.id) else { return }
        profileUpdateStatusMessage = String(format: String(localized: "Refreshing %@..."), profile.name)
        profileUpdateStatusIsFailure = false
        beginLoading()
        defer {
            endLoading()
            endProfileRefresh(profile.id)
        }

        do {
            _ = try await self.runner.refreshProfile(id: profile.id)
            await self.refreshProfiles()
            if profile.isCurrent, self.status.state == .running {
                self.status = try await self.runner.status()
                await self.loadProxyGroups()
                await self.loadCoreConfiguration()
                self.status.message = "Profile refreshed."
            }
            self.profileUpdateStatusMessage = String(format: String(localized: "%@ updated."), profile.name)
            self.profileUpdateStatusIsFailure = false
            if !profile.isCurrent || self.status.state != .running {
                self.status.message = self.profileUpdateStatusMessage
            }
            self.errorMessage = nil
        } catch {
            let message = displayMessage(for: error)
            self.errorMessage = message
            self.profileUpdateStatusMessage = String(format: String(localized: "%@ update failed."), profile.name)
            self.profileUpdateStatusIsFailure = true
            self.postProfileRefreshFailureIfNeeded(profileName: profile.name, profileID: profile.id, message: message, force: true)
        }
    }

    func deleteProfile(_ profile: ProfileSummary) async {
        await performLoadingTask { [self] in
            let deletedCurrentProfile = try await self.runner.deleteProfile(id: profile.id)
            await self.refreshProfiles()
            try await self.refreshCurrentProfileAfterTransactionIfNeeded(deletedCurrentProfile, message: "Profile deleted.")
        }
    }

    func selectProfile(_ profile: ProfileSummary) async {
        await performLoadingTask { [self] in
            try await self.runner.activateProfile(id: profile.id)
            await self.refreshProfiles()
            if self.status.state == .running {
                self.status = try await self.runner.status()
                await self.loadProxyGroups()
                await self.loadCoreConfiguration()
            }
        }
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) {
        guard status.state == .running || !isEnabled else {
            errorMessage = "Start Kumo before enabling System Proxy."
            return
        }

        Task { @MainActor in
            do {
                _ = try await runner.setSystemProxy(isEnabled)
                await refreshSystemProxyStatus()
                errorMessage = nil
            } catch {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func reclaimSystemProxy() async {
        do {
            let proxy = try await runner.reclaimSystemProxy()
            status.systemProxyEnabled = proxy.enabled
            status.systemProxyOwnership = proxy.ownership
            status.systemProxyApplied = proxy.applied
            status.systemProxySettings = proxy.settings
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func updateSystemProxySettings(_ settings: SystemProxySettings) async {
        do {
            try await runner.updateSystemProxySettings(settings)
            status.systemProxySettings = settings
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func refreshServiceModeStatus() async {
        var status = await runner.serviceModeStatus()
        if let prompt = await helperVersionRepairPrompt() {
            status.message = prompt
        }
        serviceModeStatus = status
    }

    func refreshAgentStatus() async {
        agentStatus = await runner.userAgentStatus()
    }

    /// Detection-only hint for the privileged helper: the binary under
    /// `/Library/PrivilegedHelperTools` is copied at install time and is not
    /// silently replaced on app updates. The prompt routes the user to the
    /// existing Install / Repair Service action, which performs the
    /// administrator authorization — nothing elevates on launch.
    private func helperVersionRepairPrompt() async -> String? {
        let paths = runner.paths
        let version = bundleShortVersion
        return await Task.detached(priority: .utility) {
            KumoServiceManager(paths: paths)
                .helperVersionVerdict(currentVersion: version)
                .repairMessage
        }.value
    }

    /// After an in-app update the bundle is replaced, but the LaunchAgent job
    /// registered by the previous version keeps its old plist (paths, plist
    /// shape). When the version recorded at install time no longer matches
    /// the running app — or predates stamping — re-run the idempotent install
    /// once so the job is rewritten. Skipped while a core is running or
    /// starting so a live tunnel is never torn down by the reload; the next
    /// launch repairs instead. Failures surface through `errorMessage` and
    /// never abort launch.
    private func repairInstalledAgentAfterAppUpdate() async {
        guard !didAttemptAgentUpdateRepair else { return }
        guard status.state != .running, status.state != .starting else { return }
        didAttemptAgentUpdateRepair = true

        let paths = runner.paths
        let version = bundleShortVersion
        do {
            let repaired = try await Task.detached(priority: .utility) {
                try KumoUserAgentManager(paths: paths)
                    .repairInstallIfVersionChanged(currentVersion: version)
            }.value
            if repaired != nil {
                await refreshAgentStatus()
            }
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func refreshTunStatus() async {
        do {
            tunStatus = try await runner.tunStatus()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func installServiceMode() async {
        await performLoadingTask { [self] in
            serviceModeStatus = try await runner.installServiceMode()
            await refreshStatus()
            await refreshTunStatus()
        }
    }

    func uninstallServiceMode() async {
        await performLoadingTask { [self] in
            serviceModeStatus = try await runner.uninstallServiceMode()
            await refreshStatus()
            await refreshTunStatus()
        }
    }

    func installBackgroundAgent() async {
        await performLoadingTask { [self] in
            agentStatus = try await runner.installUserAgent()
        }
    }

    func uninstallBackgroundAgent() async {
        await performLoadingTask { [self] in
            agentStatus = try await runner.uninstallUserAgent()
        }
    }

    func updateTunSettings(_ settings: TunSettings) async {
        do {
            try await runner.updateTunSettings(settings)
            var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
            runtimeSettings.tun = settings
            status.runtimeSettings = runtimeSettings
            tunStatus = try await runner.tunStatus()
            coreConfiguration.tunEnabled = settings.isEnabled
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    func applyTunSettings(_ settings: TunSettings) async {
        await performLoadingTask { [self] in
            tunStatus = try await runner.applyTunSettings(settings)
            await refreshStatus()
            await refreshServiceModeStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.tun = settings
                status.runtimeSettings = runtimeSettings
                coreConfiguration.tunEnabled = tunStatus.isEnabled
            }
        }
    }

    func setTunEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            tunStatus = try await runner.setTunEnabled(isEnabled)
            await refreshStatus()
            await refreshServiceModeStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                coreConfiguration.tunEnabled = tunStatus.isEnabled
            }
        }
    }

    // MARK: - DNS

    func setDnsSource(_ source: DnsSource) async {
        let currentSource = status.runtimeSettings?.dns?.source ?? .kumo
        guard source != currentSource, !isLoading else { return }

        await performLoadingTask { [self] in
            _ = try await runner.setDnsSource(source)
            await refreshStatus()
            currentProfileDeclaresDNS = try await runner.currentProfileDeclaresDNS()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            }
        }
    }

    func applyDnsSettings(_ settings: DnsSettings) async {
        await performLoadingTask { [self] in
            let applied = try await runner.applyDnsSettings(settings)
            await refreshStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.dns = applied
                status.runtimeSettings = runtimeSettings
                coreConfiguration.dnsEnabled = applied.isEnabled
                coreConfiguration.dns = applied
            }
        }
    }

    func setDnsEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            let settings = try await runner.setDnsEnabled(isEnabled)
            await refreshStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                coreConfiguration.dnsEnabled = settings.isEnabled
                coreConfiguration.dns = settings
            }
        }
    }

    // MARK: - Sniffer

    func applySnifferSettings(_ settings: SnifferSettings) async {
        await performLoadingTask { [self] in
            let applied = try await runner.applySnifferSettings(settings)
            await refreshStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                var runtimeSettings = status.runtimeSettings ?? CoreRuntimeSettings(mixedPort: status.proxyPorts.mixedPort)
                runtimeSettings.sniffer = applied
                status.runtimeSettings = runtimeSettings
                coreConfiguration.snifferEnabled = applied.isEnabled
                coreConfiguration.sniffer = applied
            }
        }
    }

    func setSnifferEnabled(_ isEnabled: Bool) async {
        await performLoadingTask { [self] in
            let settings = try await runner.setSnifferEnabled(isEnabled)
            await refreshStatus()
            if status.state == .running {
                try await runner.waitForControllerReady()
                await loadCoreConfiguration()
                startTrafficStream()
            } else {
                coreConfiguration.snifferEnabled = settings.isEnabled
                coreConfiguration.sniffer = settings
            }
        }
    }

    func startLogStream(level: String? = nil) {
        guard status.state == .running else { return }
        logStreamTask?.cancel()
        isStreamingLogs = true
        let selectedLevel = level ?? coreConfiguration.logLevel
        let runner = runner
        logStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await runner.logStream(level: selectedLevel)
                for try await log in stream {
                    await MainActor.run {
                        self.appendLog(log)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isStreamingLogs = false
                }
            }
        }
    }

    func stopLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
        isStreamingLogs = false
    }

    private func startTrafficStream() {
        guard status.state == .running else { return }
        trafficStreamTask?.cancel()
        let runner = runner
        trafficStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The underlying websocket stream supervises its own reconnects and yields a zero
                // snapshot when the connection drops, so we no longer need to reset on errors here.
                let stream = try await runner.trafficStream()
                for try await snapshot in stream {
                    await MainActor.run {
                        self.trafficSnapshot = snapshot
                        self.appendTrafficSample(from: snapshot)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Only reachable if KumoController couldn't construct the stream (e.g. state file
                // unreadable). Surface the disconnected state so the UI doesn't display stale data.
                await MainActor.run {
                    self.trafficSnapshot = TrafficSnapshot()
                    self.trafficHistory = []
                }
            }
        }
    }

    private func stopTrafficStream() {
        trafficStreamTask?.cancel()
        trafficStreamTask = nil
        trafficSnapshot = TrafficSnapshot()
        trafficHistory = []
    }

    private func appendTrafficSample(from snapshot: TrafficSnapshot) {
        let sample = TrafficSample(
            timestamp: Date(),
            upload: snapshot.uploadSpeed,
            download: snapshot.downloadSpeed
        )
        trafficHistory.append(sample)
        let capacity = 60
        if trafficHistory.count > capacity {
            trafficHistory.removeFirst(trafficHistory.count - capacity)
        }
    }

    func clearLogs() {
        logs = []
    }

    func loadPreferences() async {
        preferences = await runner.userPreferences()
        localizationManager?.currentLanguage = preferences.appLanguage
        if !preferences.hasCompletedOnboarding {
            showOnboarding = true
        }
    }

    func updatePreferences(_ next: UserPreferences) async {
        do {
            try await runner.updateUserPreferences(next)
            preferences = next
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    // MARK: - CLI link

    func cliLinkStatus() async -> CLILinkStatus {
        await runner.cliLinkStatus()
    }

    @discardableResult
    func installCLILink() async throws -> CLILinkStatus {
        try await runner.installCLILink()
    }

    @discardableResult
    func uninstallCLILink() async throws -> CLILinkStatus {
        try await runner.uninstallCLILink()
    }

    /// Persists onboarding completion and dismisses the sheet. Called when the
    /// user reaches the final Done step or explicitly skips it.
    func completeOnboarding() async {
        var next = preferences
        next.hasCompletedOnboarding = true
        await updatePreferences(next)
        showOnboarding = false
    }

    /// Lets Settings reopen the onboarding flow without resetting the
    /// persisted completion flag. The flag will be re-saved when the user
    /// finishes the sheet again.
    func reopenOnboarding() {
        showOnboarding = true
    }

    func startUpdatePolling() {
        guard updatePollingTask == nil else { return }
        updatePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.updatePollingIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.checkForUpdate(source: .polling)
            }
        }
    }

    func stopUpdatePolling() {
        updatePollingTask?.cancel()
        updatePollingTask = nil
    }

    func startProfileUpdatePolling() {
        guard profileUpdatePollingTask == nil else { return }
        profileUpdatePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.profileUpdatePollingIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshProfiles()
                await self?.refreshDueProfiles(source: .automatic)
            }
        }
    }

    func stopProfileUpdatePolling() {
        profileUpdatePollingTask?.cancel()
        profileUpdatePollingTask = nil
    }

    func startSystemProxyPolling() {
        guard systemProxyPollingTask == nil else { return }
        systemProxyPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.systemProxyPollingIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refreshSystemProxyStatus()
                await self?.refreshStatus()
            }
        }
    }

    func stopSystemProxyPolling() {
        systemProxyPollingTask?.cancel()
        systemProxyPollingTask = nil
    }

    func externalRevision(for domain: ControlPlaneChangeDomain) -> Int {
        externalDomainRevisions[domain, default: 0]
    }

    func startControlPlaneObservation(debounceInterval: TimeInterval = 0.2) {
        controlPlaneDebounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        guard controlPlaneObserverToken == nil else { return }
        controlPlaneObserverToken = ControlPlaneNotifier.shared.observe { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleControlPlaneChangeNotification(notification)
            }
        }
    }

    func stopControlPlaneObservation() {
        if let token = controlPlaneObserverToken {
            ControlPlaneNotifier.shared.removeObserver(token)
            controlPlaneObserverToken = nil
        }
        controlPlaneDebounceTask?.cancel()
        controlPlaneDebounceTask = nil
        pendingControlPlaneDomains.removeAll()
    }

    func refreshRollbacks() async {}

    private func handleControlPlaneChangeNotification(_ notification: ControlPlaneChangeNotification) {
        guard notification.senderPID != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        if let incomingPath = notification.appSupportPath,
           incomingPath != controller.paths.applicationSupportDirectory.standardizedFileURL.path {
            return
        }

        pendingControlPlaneDomains.formUnion(notification.domains)
        controlPlaneDebounceTask?.cancel()
        let delay = controlPlaneDebounceNanoseconds
        controlPlaneDebounceTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            let domains = self.pendingControlPlaneDomains
            self.pendingControlPlaneDomains.removeAll()
            self.controlPlaneDebounceTask = nil
            await self.applyControlPlaneChanges(domains)
        }
    }

    private func applyControlPlaneChanges(_ domains: Set<ControlPlaneChangeDomain>) async {
        guard !domains.isEmpty else { return }

        if domains.contains(.all) {
            await refreshAll()
            await refreshRollbacks()
            recordExternalChange(for: Set(ControlPlaneChangeDomain.allCases))
            return
        }

        if domains.contains(.status) {
            await refreshStatus()
            syncTrafficStreamWithStatus()
            if status.state != .running {
                trafficSnapshot = TrafficSnapshot()
                trafficHistory = []
            }
            await refreshSystemProxyStatus()
            await refreshTunStatus()
            await refreshServiceModeStatus()
            await refreshAgentStatus()
            await refreshSubStoreRuntimeStatus()
            await loadCoreConfiguration()
            await loadProxyGroups()
            await loadInspectData()
            await loadResources()
            if topology != nil {
                await loadTopology()
            }
        }

        if domains.contains(.profiles) {
            await refreshProfiles()
            if !domains.contains(.status) {
                await loadCoreConfiguration()
                await loadProxyGroups()
            }
        }

        if domains.contains(.overrides) {
            await refreshOverrides()
        }

        if (domains.contains(.profiles) || domains.contains(.overrides)),
           !domains.contains(.status),
           topology != nil {
            await loadTopology()
        }

        if domains.contains(.preferences) {
            await loadPreferences()
        }

        if domains.contains(.rollbacks) {
            await refreshRollbacks()
        }

        recordExternalChange(for: domains)
    }

    private func recordExternalChange(for domains: Set<ControlPlaneChangeDomain>) {
        externalChangeRevision += 1
        for domain in domains {
            externalDomainRevisions[domain, default: 0] += 1
        }
    }

    func checkForUpdate() async {
        await checkForUpdate(source: .manual)
    }

    private func checkForUpdate(source: AppUpdateCheckSource) async {
        guard !isCheckingForUpdates, !isPollingForUpdates else { return }
        guard !isDownloadingUpdate, !isInstallingUpdate else { return }

        switch source {
        case .manual:
            isCheckingForUpdates = true
        case .polling:
            isPollingForUpdates = true
        }
        defer {
            switch source {
            case .manual:
                isCheckingForUpdates = false
            case .polling:
                isPollingForUpdates = false
            }
        }

        do {
            let result = try await runner.checkAppUpdate(
                manifestURL: preferences.updateManifestURL,
                currentVersion: bundleShortVersion,
                channel: preferences.updateChannel
            )
            lastUpdateCheckResult = result
            if source == .manual {
                updateStatusMessage = result.update == nil ? "Kumo is up to date." : nil
            }
            if let update = result.update {
                appNotificationCoordinator.postUpdateAvailable(manifest: update)
            } else {
                appNotificationCoordinator.clearUpdateNotifications()
            }
            if source == .manual {
                errorMessage = nil
            }
        } catch {
            if source == .manual {
                errorMessage = displayMessage(for: error)
            }
        }
    }

    func downloadAndInstallUpdate(_ manifest: AppUpdateManifest) async {
        guard !isDownloadingUpdate, !isInstallingUpdate else { return }
        guard manifest.canInstallAutomatically else {
            NSWorkspace.shared.open(manifest.downloadURL)
            return
        }

        isDownloadingUpdate = true
        updateDownloadProgress = 0
        lastNotifiedDownloadBucket = 0
        updateStatusMessage = "Downloading \(manifest.version)..."
        appNotificationCoordinator.postUpdateProgress(
            manifest: manifest,
            message: "Downloading Kumo \(manifest.version)... 0%"
        )
        defer {
            isDownloadingUpdate = false
            updateDownloadProgress = nil
            lastNotifiedDownloadBucket = nil
        }

        do {
            let downloaded = try await runner.downloadAppUpdate(manifest: manifest) { [weak self] progress in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateDownloadProgress = progress
                    let percent = Int(progress * 100)
                    let bucket = max(0, min(10, percent / 10))
                    if bucket != self.lastNotifiedDownloadBucket {
                        self.lastNotifiedDownloadBucket = bucket
                        self.appNotificationCoordinator.postUpdateProgress(
                            manifest: manifest,
                            message: "Downloading Kumo \(manifest.version)... \(bucket * 10)%"
                        )
                    }
                }
            }

            updateStatusMessage = "Installing \(manifest.version)..."
            appNotificationCoordinator.postUpdateProgress(
                manifest: manifest,
                message: "Installing Kumo \(manifest.version)..."
            )
            isInstallingUpdate = true
            await prepareForUpdateInstall()

            try await runner.installAppUpdate(
                dmgURL: downloaded.fileURL,
                currentAppURL: Bundle.main.bundleURL,
                processID: ProcessInfo.processInfo.processIdentifier
            )
            updateStatusMessage = "Kumo will relaunch after installing \(manifest.version)."
            appNotificationCoordinator.postRestartReady(manifest: manifest)
            NSApplication.shared.terminate(nil)
        } catch {
            isInstallingUpdate = false
            updateStatusMessage = nil
            appNotificationCoordinator.clearUpdateNotifications()
            errorMessage = displayMessage(for: error)
        }
    }

    func handleNotificationAction(
        actionIdentifier: String,
        manifest: AppUpdateManifest?,
        version: String?
    ) async {
        let action = AppNotificationCoordinator.decodeAction(from: actionIdentifier)
        switch action {
        case .startUpdate:
            if let manifest = lastUpdateCheckResult?.update {
                await downloadAndInstallUpdate(manifest)
            } else if let manifest {
                await downloadAndInstallUpdate(manifest)
            } else {
                KumoAppContext.shared.openSettings()
            }
        case .remindLater:
            let version = version ?? lastUpdateCheckResult?.update?.version
            if let version {
                appNotificationCoordinator.snoozeReminder(for: version)
                updateStatusMessage = "Kumo \(version) reminder snoozed for 6 hours."
            }
        case .restartNow:
            NSApplication.shared.terminate(nil)
        case .openApp:
            KumoAppContext.shared.openMainWindow()
        }
    }

    func closeConnection(id: String) async {
        await performLoadingTask { [self] in
            try await runner.closeConnection(id: id)
            await loadInspectData()
        }
    }

    func closeConnections(ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        await performLoadingTask { [self] in
            for id in ids {
                try await runner.closeConnection(id: id)
            }
            await loadInspectData()
        }
    }

    func closeAllConnections() async {
        await performLoadingTask { [self] in
            try await runner.closeConnections(matchingProxy: nil)
            await loadInspectData()
        }
    }

    var subStoreLogURL: URL {
        runner.paths.subStoreLogFile
    }

    var coreLogURL: URL {
        runner.paths.coreLogFile
    }

    private var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func performLoadingTask(_ operation: @MainActor () async throws -> Void) async {
        beginLoading()
        defer { endLoading() }

        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    private func refreshDueProfiles(source: ProfileRefreshSource = .automatic) async {
        let now = Date()
        let dueProfiles = profilesDueForRefresh(now: now)
        guard !dueProfiles.isEmpty else { return }

        let currentID = currentProfile?.id
        var refreshedIDs = Set<String>()
        var refreshedNames: [String] = []
        var failures: [(profile: ProfileSummary, message: String)] = []

        for profile in dueProfiles {
            guard beginProfileRefresh(profile.id) else { continue }
            do {
                _ = try await runner.refreshProfile(id: profile.id)
                refreshedIDs.insert(profile.id)
                refreshedNames.append(profile.name)
            } catch {
                failures.append((profile, displayMessage(for: error)))
            }
            endProfileRefresh(profile.id)
        }

        if !refreshedIDs.isEmpty {
            await refreshProfiles()
            if currentID.map({ refreshedIDs.contains($0) }) == true, status.state == .running {
                status = (try? await runner.status()) ?? status
                await loadProxyGroups()
                await loadCoreConfiguration()
                status.message = "Profiles auto-updated."
            }

            profileUpdateStatusMessage = profileRefreshSummary(names: refreshedNames)
            profileUpdateStatusIsFailure = false
            if source == .automatic {
                appNotificationCoordinator.postProfilesAutoUpdated(
                    count: refreshedNames.count,
                    names: refreshedNames
                )
            }
        }

        if let firstFailure = failures.first {
            errorMessage = firstFailure.message
            profileUpdateStatusMessage = String(format: String(localized: "%@ update failed."), firstFailure.profile.name)
            profileUpdateStatusIsFailure = true
            postProfileRefreshFailureIfNeeded(
                profileName: firstFailure.profile.name,
                profileID: firstFailure.profile.id,
                message: firstFailure.message,
                force: source == .manual
            )
        } else if !refreshedIDs.isEmpty {
            errorMessage = nil
        }
    }

    private func refreshCurrentProfileAfterTransactionIfNeeded(_ wasCurrent: Bool, message: String) async throws {
        guard wasCurrent, status.state == .running else {
            return
        }

        status = try await runner.status()
        await loadProxyGroups()
        await loadCoreConfiguration()
        await loadTopology()
        await loadInspectData()
        status.message = message
    }

    private func activateCurrentProfileAfterImport() async throws {
        let installResult: CoreInstallResult?

        if status.state == .running {
            installResult = nil
            status = try await runner.restart()
        } else {
            installResult = try await installManagedCoreIfNeeded()
            status = try await runner.start()
        }

        try await runner.waitForControllerReady()
        startTrafficStream()
        await loadProxyGroups()
        await loadCoreConfiguration()
        await loadInspectData()

        if let installResult {
            status.message = "Imported profile, installed Mihomo core \(installResult.version), and started."
        } else {
            status.message = "Imported profile and activated it."
        }
    }

    @discardableResult
    private func installManagedCoreIfNeeded() async throws -> CoreInstallResult? {
        let candidates = try await runner.coreCandidates()
        coreCandidates = candidates

        guard candidates.isEmpty else {
            return nil
        }

        isInstallingCore = true
        defer { isInstallingCore = false }

        let result = try await runner.installManagedCore()
        coreCandidates = try await runner.coreCandidates()
        return result
    }

    private func beginLoading() {
        loadingTaskCount += 1
        isLoading = true
    }

    private func endLoading() {
        loadingTaskCount = max(0, loadingTaskCount - 1)
        isLoading = loadingTaskCount > 0
    }

    private func appendLog(_ log: LogEntry) {
        logs.append(log)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    private func syncTrafficStreamWithStatus() {
        if status.state == .running {
            startTrafficStream()
        } else {
            stopTrafficStream()
        }
    }

    private func displayMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func profilesDueForRefresh(now: Date) -> [ProfileSummary] {
        profiles.filter { profile in
            guard profile.kind == .remote, profile.autoUpdate else { return false }
            guard let interval = profile.updateIntervalSeconds, interval > 0 else { return false }
            let updatedAt = profile.updatedAt ?? .distantPast
            return now.timeIntervalSince(updatedAt) >= TimeInterval(interval)
        }
    }

    private func beginProfileRefresh(_ id: String) -> Bool {
        guard !refreshingProfileIDs.contains(id) else { return false }
        refreshingProfileIDs.insert(id)
        return true
    }

    private func endProfileRefresh(_ id: String) {
        refreshingProfileIDs.remove(id)
    }

    private func profileRefreshSummary(names: [String]) -> String {
        if names.count == 1, let name = names.first {
            return String(format: String(localized: "%@ updated."), name)
        }
        return String(format: String(localized: "%d profiles updated."), names.count)
    }

    private func postProfileRefreshFailureIfNeeded(
        profileName: String,
        profileID: String,
        message: String,
        force: Bool = false
    ) {
        let now = Date()
        let lastNotifiedAt = lastProfileRefreshFailureNotifications[profileID]
        let shouldNotify = force || lastNotifiedAt.map { now.timeIntervalSince($0) >= 6 * 60 * 60 } ?? true
        guard shouldNotify else { return }

        lastProfileRefreshFailureNotifications[profileID] = now
        appNotificationCoordinator.postProfileRefreshFailed(profileName: profileName, error: message)
    }
}
