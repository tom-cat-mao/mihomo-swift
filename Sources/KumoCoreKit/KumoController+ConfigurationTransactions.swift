import Foundation

public struct ConfigurationDiffReport: Codable, Equatable, Sendable {
    public let changed: Bool
    public let diff: String

    public init(changed: Bool, diff: String) {
        self.changed = changed
        self.diff = diff
    }
}

public struct ConfigurationValidationReport: Codable, Equatable, Sendable {
    public let valid: Bool
    public let diagnostics: [String]

    public init(valid: Bool, diagnostics: [String]) {
        self.valid = valid
        self.diagnostics = diagnostics
    }
}

public struct ConfigurationApplyReport: Codable, Equatable, Sendable {
    public let rollbackPointID: String
    public let snapshotCount: Int
    public let reloaded: Bool

    public init(rollbackPointID: String, snapshotCount: Int, reloaded: Bool) {
        self.rollbackPointID = rollbackPointID
        self.snapshotCount = snapshotCount
        self.reloaded = reloaded
    }
}

public struct ConfigurationRollbackReport: Codable, Equatable, Sendable {
    public let rollbackPointID: String
    public let remainingSnapshots: Int
    public let reloaded: Bool

    public init(rollbackPointID: String, remainingSnapshots: Int, reloaded: Bool) {
        self.rollbackPointID = rollbackPointID
        self.remainingSnapshots = remainingSnapshots
        self.reloaded = reloaded
    }
}

extension KumoController {
    public func rollbackSummaries() throws -> [ConfigurationRollbackSummary] {
        try ConfigurationRollbackStore(paths: paths).summaries()
    }

    public func rollbackPointCount() throws -> Int {
        try ConfigurationRollbackStore(paths: paths).count()
    }

    /// Builds and preflights the current candidate. A running core uses a full
    /// `PUT /configs?force=true` reload; a stopped core does no work here and is
    /// validated by `start()` before its last known-good file can be replaced.
    public func reloadRuntimeConfiguration() async throws {
        let status = try stateStore.load()
        guard status.state == .running else { return }
        let previousConfiguration = supervisor.runtimeConfigurationData()
        _ = try supervisor.validateConfiguration(try currentLaunchConfiguration())

        do {
            try await performConfigurationReload()
            supervisor.appendRuntimeEvent(kind: "config.reload", message: "Runtime configuration reloaded.")
            notifyControlPlaneChanged([.status])
        } catch {
            var diagnostics: [String] = []
            do {
                try supervisor.restoreRuntimeConfiguration(previousConfiguration)
            } catch {
                diagnostics.append("restore config: \(error.localizedDescription)")
            }
            // A transport failure is ambiguous: the core may have read part of
            // the candidate. Restore the old file and ask it to read that file
            // again, without stopping the process or changing its owner tier.
            do {
                try await performConfigurationReload()
            } catch {
                diagnostics.append("reload previous config: \(error.localizedDescription)")
            }
            let base = supervisor.failureMessage("Mihomo configuration hot reload failed: \(error.localizedDescription)")
            let suffix = diagnostics.isEmpty ? "" : " Rollback problems: \(diagnostics.joined(separator: "; "))"
            throw KumoError.commandFailed(base + suffix)
        }
    }

    /// Returns a deterministic diff from the last installed generated runtime
    /// configuration to the requested current-profile candidate. No core is
    /// launched and no application-support file is created or changed.
    public func diffConfiguration(profileYAML: String? = nil) throws -> ConfigurationDiffReport {
        let candidate = try supervisor.buildRuntimeConfiguration(
            try launchConfiguration(profileYAML: profileYAML)
        )
        let previous = supervisor.runtimeConfigurationData().flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        return ConfigurationDiffReport(
            changed: previous != candidate.yaml,
            diff: unifiedConfigurationDiff(previous: previous, candidate: candidate.yaml)
        )
    }

    /// Runs the selected core's real `mihomo -t` against the candidate in an
    /// isolated temporary directory. Build and core failures are returned as
    /// diagnostics rather than flattened into a success/error boolean alone.
    public func validateConfiguration(profileYAML: String? = nil) -> ConfigurationValidationReport {
        do {
            _ = try supervisor.validateConfiguration(
                try launchConfiguration(profileYAML: profileYAML),
                install: false
            )
            return ConfigurationValidationReport(valid: true, diagnostics: [])
        } catch {
            return ConfigurationValidationReport(
                valid: false,
                diagnostics: [configurationDiagnostic(error)]
            )
        }
    }

    /// Replaces the current profile through the existing transactional update
    /// path. The pending pre-apply state becomes a rollback point only after
    /// validation/install and, when running, forced hot reload have succeeded.
    public func applyConfiguration(profileYAML rawYAML: String) async throws -> ConfigurationApplyReport {
        guard let current = try profileRepository.listProfiles().first(where: \.isCurrent) else {
            throw KumoError.invalidArguments("No current profile is available.")
        }
        let status = try stateStore.load()
        let wasRunning = status.state == .running
        let store = ConfigurationRollbackStore(paths: paths)
        let staged = try store.stage(
            profiles: try profileRepository.transactionSnapshot(),
            overrides: try overrideRepository.transactionSnapshot(),
            status: status,
            runtimeConfiguration: supervisor.runtimeConfigurationData(),
            source: "config-apply",
            summary: current.name.isEmpty ? "Profile configuration apply" : current.name
        )

        do {
            try await performProfileTransaction(reload: wasRunning) {
                _ = try profileRepository.updateProfile(
                    id: current.id,
                    name: current.name,
                    remoteURL: current.remoteURL,
                    autoUpdate: current.autoUpdate,
                    useProxy: current.useProxy,
                    rawYAML: rawYAML
                )
                if !wasRunning {
                    _ = try supervisor.validateConfiguration(try currentLaunchConfiguration())
                }
            }
        } catch {
            store.discard(staged)
            throw error
        }

        do {
            let count = try store.commit(staged)
            supervisor.appendRuntimeEvent(
                kind: "config.apply",
                message: "Configuration applied; rollback point \(staged.point.id)."
            )
            notifyControlPlaneChanged([.profiles, .rollbacks, .status])
            return ConfigurationApplyReport(
                rollbackPointID: staged.point.id,
                snapshotCount: count,
                reloaded: wasRunning
            )
        } catch {
            // A point that could not be committed must not leave an apparently
            // successful apply without its promised recovery path.
            store.discard(staged)
            var diagnostics: [String] = []
            do {
                try restoreConfigurationPoint(staged.point, preserving: try stateStore.load())
                if wasRunning {
                    try await reloadRuntimeConfiguration()
                }
            } catch {
                diagnostics.append(configurationDiagnostic(error))
            }
            let suffix = diagnostics.isEmpty ? "" : " Recovery problems: \(diagnostics.joined(separator: "; "))"
            throw KumoError.commandFailed("The configuration was restored because its rollback point could not be committed: \(configurationDiagnostic(error))\(suffix)")
        }
    }

    /// Restores the newest successful pre-apply state. A running core is
    /// preflighted and hot-reloaded before the point is consumed. Any failure
    /// restores the pre-rollback state and leaves the point available to retry.
    public func rollbackConfiguration() async throws -> ConfigurationRollbackReport {
        let store = ConfigurationRollbackStore(paths: paths)
        guard let point = try store.latest() else {
            throw KumoError.invalidArguments("No successful configuration apply is available to roll back.")
        }

        let currentProfiles = try profileRepository.transactionSnapshot()
        let currentOverrides = try overrideRepository.transactionSnapshot()
        let currentStatus = try stateStore.load()
        let currentRuntime = supervisor.runtimeConfigurationData()
        let wasRunning = currentStatus.state == .running

        do {
            try restoreConfigurationPoint(point, preserving: currentStatus)
            if wasRunning {
                try await reloadRuntimeConfiguration()
            }
            let remainingSnapshots = try store.count() - 1
            try store.consume(id: point.id)
            supervisor.appendRuntimeEvent(
                kind: "config.rollback",
                message: "Configuration rolled back to point \(point.id)."
            )
            notifyControlPlaneChanged([.all])
            return ConfigurationRollbackReport(
                rollbackPointID: point.id,
                remainingSnapshots: remainingSnapshots,
                reloaded: wasRunning
            )
        } catch {
            let rollbackError = configurationDiagnostic(error)
            var diagnostics: [String] = []
            do {
                try profileRepository.restoreTransactionSnapshot(currentProfiles)
            } catch {
                diagnostics.append("restore current profiles: \(configurationDiagnostic(error))")
            }
            do {
                try overrideRepository.restoreTransactionSnapshot(currentOverrides)
            } catch {
                diagnostics.append("restore current overrides: \(configurationDiagnostic(error))")
            }
            do {
                var status = try stateStore.load()
                status.copyConfigurationFields(from: currentStatus)
                try stateStore.save(status)
            } catch {
                diagnostics.append("restore current core configuration: \(configurationDiagnostic(error))")
            }
            do {
                try supervisor.restoreRuntimeConfiguration(currentRuntime)
            } catch {
                diagnostics.append("restore current runtime file: \(configurationDiagnostic(error))")
            }
            if wasRunning {
                do {
                    try await reloadRuntimeConfiguration()
                } catch {
                    diagnostics.append("reload current runtime: \(configurationDiagnostic(error))")
                }
            }
            let suffix = diagnostics.isEmpty ? "" : " Recovery problems: \(diagnostics.joined(separator: "; "))"
            throw KumoError.commandFailed(
                "Configuration rollback failed; the rollback point was retained: \(rollbackError)\(suffix)"
            )
        }
    }

    /// Transactionally selects a subscription and hot-reloads it when running.
    /// On failure the profile files, metadata and `current.txt` are restored.
    public func activateProfile(id: String) async throws {
        try await performProfileTransaction(reload: true) {
            try profileRepository.setCurrentProfile(id: id)
        }
        notifyControlPlaneChanged([.profiles, .status])
    }

    @discardableResult
    public func createLocalOverride(
        name: String,
        format: OverrideFormat,
        content: String,
        isGlobal: Bool = false
    ) async throws -> OverrideItem {
        try await performOverrideTransaction {
            try overrideRepository.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
        }
    }

    @discardableResult
    public func createRemoteOverride(
        url: URL,
        name: String? = nil,
        format: OverrideFormat = .yaml,
        fingerprint: String? = nil,
        isGlobal: Bool = false
    ) async throws -> OverrideItem {
        try await performOverrideTransaction {
            try await overrideRepository.addRemoteOverride(
                url: url,
                name: name,
                format: format,
                fingerprint: fingerprint,
                isGlobal: isGlobal
            )
        }
    }

    public func changeOverride(_ item: OverrideItem, content: String? = nil) async throws {
        try await performOverrideTransaction {
            try overrideRepository.updateOverride(item, content: content)
        }
    }

    public func removeOverride(id: String) async throws {
        try await performOverrideTransaction {
            try overrideRepository.deleteOverride(id: id)
        }
    }

    public func changeOverrideOrder(ids: [String]) async throws {
        try await performOverrideTransaction {
            try overrideRepository.reorderOverrides(ids: ids)
        }
    }

    func currentLaunchConfiguration(
        corePath: String? = nil,
        runtimeSettings candidateRuntimeSettings: CoreRuntimeSettings? = nil
    ) throws -> CoreLaunchConfiguration {
        try launchConfiguration(
            profileYAML: nil,
            corePath: corePath,
            runtimeSettings: candidateRuntimeSettings
        )
    }

    private func launchConfiguration(
        profileYAML: String?,
        corePath: String? = nil,
        runtimeSettings candidateRuntimeSettings: CoreRuntimeSettings? = nil
    ) throws -> CoreLaunchConfiguration {
        let status = try stateStore.load()
        var profile = try profileRepository.loadDefaultProfile()
        if let profileYAML {
            try profileRepository.validateProfileYAML(profileYAML)
            profile.rawYAML = profileYAML
        }
        let overrides = try overrideRepository.activeOverrides()
        let transformedProfile = try RuntimeConfigBuilder().applyingOverrides(overrides, to: profile)
        return CoreLaunchConfiguration(
            corePath: corePath ?? status.corePath,
            profile: transformedProfile,
            overrideYAMLs: [],
            endpoint: status.endpoint,
            proxyPorts: status.proxyPorts,
            mode: status.mode,
            runtimeSettings: candidateRuntimeSettings ?? runtimeSettings(for: status)
        )
    }

    /// Every restart that requires a new generated file validates it before the
    /// running core is stopped. Socket tiers execute this inside their own
    /// internal controller, preserving the two-tier ownership boundary.
    func preflightCurrentConfiguration(corePath: String? = nil) throws {
        _ = try supervisor.validateConfiguration(try currentLaunchConfiguration(corePath: corePath))
    }

    func performProfileTransaction<T>(
        reload: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        let snapshot = try profileRepository.transactionSnapshot()
        let previousConfiguration = supervisor.runtimeConfigurationData()
        let wasRunning = try stateStore.load().state == .running
        do {
            let result = try await operation()
            if reload, wasRunning {
                try await reloadRuntimeConfiguration()
            }
            return result
        } catch {
            var diagnostics: [String] = []
            do {
                try profileRepository.restoreTransactionSnapshot(snapshot)
            } catch {
                diagnostics.append("restore profiles: \(error.localizedDescription)")
            }
            do {
                try supervisor.restoreRuntimeConfiguration(previousConfiguration)
            } catch {
                diagnostics.append("restore config: \(error.localizedDescription)")
            }
            guard !diagnostics.isEmpty else { throw error }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw KumoError.commandFailed("\(message) Rollback problems: \(diagnostics.joined(separator: "; "))")
        }
    }

    private func performOverrideTransaction<T>(
        operation: () async throws -> T
    ) async throws -> T {
        let snapshot = try overrideRepository.transactionSnapshot()
        let previousConfiguration = supervisor.runtimeConfigurationData()
        let wasRunning = try stateStore.load().state == .running
        do {
            let result = try await operation()
            if wasRunning {
                try await reloadRuntimeConfiguration()
            }
            notifyControlPlaneChanged(wasRunning ? [.overrides, .status] : [.overrides])
            return result
        } catch {
            var diagnostics: [String] = []
            do {
                try overrideRepository.restoreTransactionSnapshot(snapshot)
            } catch {
                diagnostics.append("restore overrides: \(error.localizedDescription)")
            }
            do {
                try supervisor.restoreRuntimeConfiguration(previousConfiguration)
            } catch {
                diagnostics.append("restore config: \(error.localizedDescription)")
            }
            guard !diagnostics.isEmpty else { throw error }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw KumoError.commandFailed("\(message) Rollback problems: \(diagnostics.joined(separator: "; "))")
        }
    }

    private func restoreConfigurationPoint(
        _ point: ConfigurationRollbackStore.Point,
        preserving currentStatus: CoreStatus
    ) throws {
        try profileRepository.restoreTransactionSnapshot(point.profiles)
        try overrideRepository.restoreTransactionSnapshot(point.overrides)
        var restoredStatus = currentStatus
        restoredStatus.copyConfigurationFields(from: point.status)
        try stateStore.save(restoredStatus)
        try supervisor.restoreRuntimeConfiguration(point.runtimeConfiguration)
    }

    private func configurationDiagnostic(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func performConfigurationReload() async throws {
        if let configurationReloader {
            try await configurationReloader(paths.runtimeConfigFile.path)
        } else {
            let status = try stateStore.load()
            try await MihomoControllerClient(endpoint: status.endpoint).reloadConfiguration(
                path: paths.runtimeConfigFile.path
            )
        }
    }
}

private extension CoreStatus {
    /// Process identity, lifecycle observations and every system-proxy field
    /// stay at their current values. Only inputs to generated configuration are
    /// restored from a rollback point.
    mutating func copyConfigurationFields(from snapshot: CoreStatus) {
        mode = snapshot.mode
        endpoint = snapshot.endpoint
        proxyPorts = snapshot.proxyPorts
        runtimeSettings = snapshot.runtimeSettings
    }
}

private func unifiedConfigurationDiff(previous: String, candidate: String) -> String {
    guard previous != candidate else { return "" }
    let oldLines = diffLines(previous)
    let newLines = diffLines(candidate)
    var prefix = 0
    while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
        prefix += 1
    }
    var suffix = 0
    while suffix < oldLines.count - prefix,
          suffix < newLines.count - prefix,
          oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
        suffix += 1
    }

    let contextBefore = min(3, prefix)
    let contextAfter = min(3, suffix)
    let start = prefix - contextBefore
    let oldChangeEnd = oldLines.count - suffix
    let newChangeEnd = newLines.count - suffix
    let oldCount = contextBefore + (oldChangeEnd - prefix) + contextAfter
    let newCount = contextBefore + (newChangeEnd - prefix) + contextAfter
    let oldStart = oldCount == 0 ? 0 : start + 1
    let newStart = newCount == 0 ? 0 : start + 1

    var lines = [
        "--- a/work/config.yaml",
        "+++ b/work/config.yaml",
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    ]
    if contextBefore > 0 {
        lines.append(contentsOf: oldLines[start..<prefix].map { " \($0)" })
    }
    lines.append(contentsOf: oldLines[prefix..<oldChangeEnd].map { "-\($0)" })
    lines.append(contentsOf: newLines[prefix..<newChangeEnd].map { "+\($0)" })
    if contextAfter > 0 {
        lines.append(contentsOf: oldLines[oldChangeEnd..<(oldChangeEnd + contextAfter)].map { " \($0)" })
    }
    return lines.joined(separator: "\n")
}

private func diffLines(_ text: String) -> [String] {
    text.isEmpty ? [] : text.components(separatedBy: "\n")
}
