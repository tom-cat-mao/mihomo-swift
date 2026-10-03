import Foundation
import os

/// Logs tier-routing decisions and fallbacks. Shared with `KumoCoreKit.swift`,
/// where a socket tier that fails mid-call degrades to the shared state read.
let routingLogger = Logger(subsystem: "io.kumo.KumoApp", category: "runtime-routing")

// MARK: - Backend routing

extension KumoController {
    /// The tier that must execute the next core-lifecycle operation, or the
    /// failure reason when TUN is active and no privileged executor is reachable.
    func requiredCoreBackend() throws -> RuntimeBackend {
        let decision = router.decideCoreBackend(tunEnabled: currentTunEnabled())
        if let backend = decision.backend {
            return backend
        }
        throw KumoError.serviceUnavailable(
            decision.unavailableReason
                ?? "The runtime tier required for this operation is not reachable."
        )
    }

    /// Client for a socket-tier decision. A nil result (missing credentials, or
    /// a decision that is not a socket tier) is why read-only callers fall back
    /// to the shared state file instead of failing.
    func serviceClient(for decision: CoreBackendDecision) -> KumoServiceClient? {
        switch decision.backend {
        case .rootService: rootServiceClient()
        case .userAgent: userAgentClient()
        case .localSupervisor, .none: nil
        }
    }

    /// Awaits controller readiness through the injected waiter when tests need
    /// to skip the HTTP endpoint, and through `waitForControllerReady()`
    /// otherwise.
    func awaitControllerReadiness() async throws {
        if let readinessWaiter {
            try await readinessWaiter()
        } else {
            try await waitForControllerReady()
        }
    }

    // MARK: Tier lifecycle operations

    func performTierStop(_ backend: RuntimeBackend) throws -> CoreStatus {
        if let tierOperations {
            return try tierOperations.stop(backend)
        }
        switch backend {
        case .localSupervisor:
            return try supervisor.stop()
        case .rootService:
            guard let client = rootServiceClient() else {
                throw KumoError.serviceUnavailable("Kumo Helper is not reachable.")
            }
            return try client.sendDecodable(client.stopCoreRequest(), as: CoreStatus.self)
        case .userAgent:
            guard let client = userAgentClient() else {
                throw KumoError.serviceUnavailable("The Kumo agent is not reachable.")
            }
            return try client.sendDecodable(client.stopCoreRequest(), as: CoreStatus.self)
        }
    }

    func performTierStart(_ backend: RuntimeBackend) throws -> CoreStatus {
        if let tierOperations {
            return try tierOperations.start(backend)
        }
        switch backend {
        case .localSupervisor:
            return try startLocalCore(corePath: nil)
        case .rootService:
            guard let client = rootServiceClient() else {
                throw KumoError.serviceUnavailable("Kumo Helper is not reachable.")
            }
            return try client.sendDecodable(client.startCoreRequest(), as: CoreStatus.self)
        case .userAgent:
            guard let client = userAgentClient() else {
                throw KumoError.serviceUnavailable("The Kumo agent is not reachable.")
            }
            return try client.sendDecodable(client.startCoreRequest(), as: CoreStatus.self)
        }
    }

    /// Explicit ownership transfer between runtime tiers.
    ///
    /// Sequence: stop the core on `source`, run `prepare` (the shared-state
    /// writes the target must observe before it starts), then start the core on
    /// `target`. Stopping and starting exposes a short traffic gap while the
    /// new core initializes.
    ///
    /// When the target fails to start, `rollback` restores the previous shared
    /// state and the helper restarts the core on the source tier, so a failed
    /// handoff does not strand the machine without a core. The thrown error
    /// names the target failure and every rollback outcome.
    @discardableResult
    func transferCoreOwnership(
        from source: RuntimeBackend,
        to target: RuntimeBackend,
        prepare: @Sendable () throws -> Void = {},
        rollback: @Sendable () throws -> Void = {}
    ) throws -> CoreStatus {
        _ = try performTierStop(source)

        do {
            try prepare()
        } catch {
            // The target can never start without the prepared state; put the
            // core back on the source tier as it was.
            _ = try? performTierStart(source)
            throw error
        }

        do {
            return try performTierStart(target)
        } catch {
            var diagnostics: [String] = []
            do {
                try rollback()
            } catch {
                diagnostics.append(formatDiagnostic(stage: "handoff-rollback", error: error))
            }
            do {
                _ = try performTierStart(source)
            } catch {
                diagnostics.append(formatDiagnostic(stage: "handoff-restore", error: error))
            }
            let targetMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var message = "Moving the core from \(source.displayName) to \(target.displayName) failed: \(targetMessage)"
            if !diagnostics.isEmpty {
                message += " Rollback problems: \(diagnostics.joined(separator: "; "))"
            }
            throw KumoError.serviceUnavailable(message)
        }
    }
}

// MARK: - TUN ownership transitions

extension KumoController {
    /// Shared implementation of `applyTunSettings(_:)` and `setTunEnabled(_:)`.
    ///
    /// Beyond persisting the setting, this enforces the ownership rule:
    ///
    /// - Enabling TUN while the user agent owns a running core stops the core
    ///   through the agent and starts it through the root daemon (root-owned),
    ///   with a short traffic gap.
    /// - Disabling TUN while the root daemon owns a running core hands the core
    ///   back to the user agent when one is reachable, so the GUI can quit
    ///   without killing it later.
    /// - Every other TUN-on change keeps the historical root-or-local executor.
    /// - Every other TUN-off change is applied through the current owner (agent
    ///   when reachable, otherwise local) so ownership does not move to root.
    @discardableResult
    func updateTunSettingsFlow(_ requested: TunSettings) async throws -> TunStatus {
        var status = try stateStore.load()
        let service = currentServiceStatus()
        let runtimeSettings = runtimeSettings(for: status)
        let previousTun = runtimeSettings.tun ?? TunSettings()
        let normalized = normalizedTunSettings(requested)

        if normalized.isEnabled, !service.canManageTun {
            let message = service.message ?? "TUN requires the Kumo privileged helper."
            status.serviceModeStatus = service
            status.tunStatus = TunStatus(isEnabled: false, isRunning: false, requiresService: true, lastError: message)
            try stateStore.save(status)
            throw KumoError.serviceUnavailable(message)
        }

        let enableTransition = normalized.isEnabled && !previousTun.isEnabled
        let disableTransition = !normalized.isEnabled && previousTun.isEnabled
        let coreIsRunning = status.state == .running
        let rootReachable = router.privilegedBackend() == .rootService
        let agentReachable = router.decideCoreBackend(tunEnabled: false).backend == .userAgent

        let updatedStatus = statusApplyingTun(normalized, to: status, service: service)

        // 1. Explicit ownership handoffs on tier transitions.
        if coreIsRunning, enableTransition, agentReachable, rootReachable {
            return try await transferTunOwnership(
                from: .userAgent,
                to: .rootService,
                updatedStatus: updatedStatus,
                previousStatus: status
            )
        }
        if coreIsRunning, disableTransition, agentReachable, rootReachable {
            return try await transferTunOwnership(
                from: .rootService,
                to: .userAgent,
                updatedStatus: updatedStatus,
                previousStatus: nil
            )
        }

        // 2. TUN-on operations (enabling or already enabled): the privileged
        //    tier is the executor, preserving the historical root-or-local
        //    behavior. The root daemon's own restart also performs an implicit
        //    local → root handoff when a direct-mode core is running.
        if normalized.isEnabled || previousTun.isEnabled {
            if let client = privilegedServiceClient() {
                let request = try client.applyTunSettingsRequest(normalized)
                return try client.sendDecodable(request, as: TunStatus.self)
            }
            return try await applyTunLocally(normalized, status: status, service: service)
        }

        // 3. TUN stays off: apply through the core's current owner so the
        //    operation cannot move ownership to the root daemon.
        if coreIsRunning, agentReachable {
            return try await applyTunThroughAgent(normalized, status: status, service: service)
        }
        return try await applyTunLocally(normalized, status: status, service: service)
    }

    /// Persists the shared status with the requested TUN settings applied.
    /// `runtimeSettings` normalization is shared with the public
    /// `updateTunSettings(_:)`.
    private func statusApplyingTun(
        _ settings: TunSettings,
        to status: CoreStatus,
        service: ServiceModeStatus
    ) -> CoreStatus {
        var updated = status
        var runtimeSettings = runtimeSettings(for: status)
        runtimeSettings.tun = settings
        updated.runtimeSettings = runtimeSettings
        updated.proxyPorts.mixedPort = runtimeSettings.mixedPort
        updated.serviceModeStatus = service
        updated.tunStatus = TunStatus(
            isEnabled: settings.isEnabled,
            isRunning: status.state == .running && settings.isEnabled && service.canManageTun,
            requiresService: !service.canManageTun,
            lastError: nil
        )
        return updated
    }

    /// Stops the core on `source`, starts it on `target`, and waits for the new
    /// controller. On failure the state is rolled back to `previousStatus` (when
    /// provided) and the source tier restarts the core.
    private func transferTunOwnership(
        from source: RuntimeBackend,
        to target: RuntimeBackend,
        updatedStatus: CoreStatus,
        previousStatus: CoreStatus?
    ) async throws -> TunStatus {
        _ = try transferCoreOwnership(
            from: source,
            to: target,
            prepare: { try stateStore.save(updatedStatus) },
            rollback: {
                if let previousStatus {
                    try stateStore.save(previousStatus)
                }
            }
        )
        try await awaitControllerReadiness()
        routingLogger.info(
            "Core ownership moved from \(source.rawValue, privacy: .public) to \(target.rawValue, privacy: .public)."
        )
        return try tunStatus()
    }

    /// TUN-off setting change applied through the user agent, which owns the
    /// core when TUN is off.
    private func applyTunThroughAgent(
        _ settings: TunSettings,
        status: CoreStatus,
        service: ServiceModeStatus
    ) async throws -> TunStatus {
        try stateStore.save(statusApplyingTun(settings, to: status, service: service))

        if status.state == .running {
            guard let client = userAgentClient() else {
                throw KumoError.serviceUnavailable("The Kumo agent is not reachable.")
            }
            _ = try client.sendDecodable(client.restartCoreRequest(), as: CoreStatus.self)
            try await awaitControllerReadiness()
        }

        return try tunStatus()
    }

    /// Historical direct-mode path: persist the setting and restart the core in
    /// the calling process. Reachable only when no socket tier is selected, or
    /// when the calling process is privileged and can own TUN itself.
    private func applyTunLocally(
        _ settings: TunSettings,
        status: CoreStatus,
        service: ServiceModeStatus
    ) async throws -> TunStatus {
        try stateStore.save(statusApplyingTun(settings, to: status, service: service))

        if status.state == .running {
            _ = try performTierStop(.localSupervisor)
            _ = try performTierStart(.localSupervisor)
            try await awaitControllerReadiness()
        }

        return try tunStatus()
    }
}

// MARK: - App termination policy

/// What the GUI should do with the running runtime when the app terminates.
public enum AppTerminationPolicy: String, CaseIterable, Sendable {
    /// Today's behavior: disable Kumo-managed system proxy state and stop the
    /// running Mihomo core (`shutdownActiveRuntime()` semantics).
    case stopRuntime

    /// Leave everything running — including the system proxy and a core owned
    /// by the user agent or the root daemon — so the core keeps serving after
    /// the GUI quits. This is the policy that relies on the user agent owning
    /// the core; in direct mode the core is a child of this process.
    case keepCoreAlive
}

extension KumoController {
    /// Best-effort preparation for app termination. Never throws: failures land
    /// in `ShutdownResult.diagnostics`, and the returned status is the most
    /// recent observable one (falling back to the on-disk state).
    ///
    /// - `.stopRuntime`: disable Kumo-managed system proxy state, then stop the
    ///   running core through whichever tier owns it.
    /// - `.keepCoreAlive`: disable nothing and stop nothing; only read the
    ///   current status so the caller can surface it (and diagnose a failed
    ///   read).
    @discardableResult
    public func prepareForAppTermination(policy: AppTerminationPolicy = .stopRuntime) async -> ShutdownResult {
        switch policy {
        case .stopRuntime:
            return await shutdownActiveRuntime()
        case .keepCoreAlive:
            return await prepareToKeepCoreAlive()
        }
    }

    private func prepareToKeepCoreAlive() async -> ShutdownResult {
        var diagnostics: [String] = []
        var latestStatus: CoreStatus
        do {
            latestStatus = try status()
        } catch {
            diagnostics.append(formatDiagnostic(stage: "status", error: error))
            latestStatus = (try? stateStore.load()) ?? CoreStatus()
        }
        return ShutdownResult(status: latestStatus, diagnostics: diagnostics)
    }
}
