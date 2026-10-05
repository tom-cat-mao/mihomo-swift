import Foundation
import os

/// Which launchd tiers are installed, which tier the router currently selects
/// to own the Mihomo core, and the TUN state that drives that decision.
///
/// This is the public reporting surface of the two-tier runtime: the GUI can
/// show "Kumo Helper only / agent only / both installed" without duplicating
/// the per-tier status reads, and the CLI's `kumo agent migrate --dry-run`
/// prints it. The core owner comes from `BackendRouter` — the same routing
/// that every lifecycle operation uses — not from a per-tier status call,
/// because both tiers read the same shared `state.json`.
public struct TierInstallState: Codable, Equatable, Sendable {
    /// Install combination of the privileged LaunchDaemon and the user
    /// LaunchAgent.
    public enum InstallState: String, Codable, Sendable, CaseIterable {
        case none
        case rootOnly
        case userOnly
        case dual
    }

    /// The tier backing the next core operation. `unavailable` means TUN is
    /// enabled and no privileged executor is reachable, so the router refuses
    /// to pick a user-owned tier (see `CoreBackendDecision.unavailable`).
    public enum CoreOwner: String, Codable, Sendable, CaseIterable {
        case rootService
        case userAgent
        case localSupervisor
        case unavailable
    }

    public var installState: InstallState
    public var coreOwner: CoreOwner
    public var tunEnabled: Bool
    public var rootService: ServiceModeStatus
    public var userAgent: ServiceModeStatus
    /// Populated when `coreOwner == .unavailable`.
    public var ownerUnavailableReason: String?

    public init(
        installState: InstallState,
        coreOwner: CoreOwner,
        tunEnabled: Bool,
        rootService: ServiceModeStatus,
        userAgent: ServiceModeStatus,
        ownerUnavailableReason: String? = nil
    ) {
        self.installState = installState
        self.coreOwner = coreOwner
        self.tunEnabled = tunEnabled
        self.rootService = rootService
        self.userAgent = userAgent
        self.ownerUnavailableReason = ownerUnavailableReason
    }
}

/// What `KumoController.migrateCoreToUserAgent()` would do, without doing it.
///
/// A plan never throws for its guards; refusal reasons are reported in
/// `blockers`, so `kumo agent migrate --dry-run` can print a complete answer
/// on a TUN-enabled or agent-less host instead of failing.
public struct CoreMigrationPlan: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// The running core is root-owned and would be handed to the agent.
        case handoff
        /// Nothing to do; see `reason`.
        case none
    }

    public var action: Action
    public var tier: TierInstallState
    public var coreRunning: Bool
    /// Every guard that would make the real migration refuse, in evaluation
    /// order. Empty when the plan is executable.
    public var blockers: [String]
    /// Why no handoff is planned (`action == .none`), or the first blocker.
    public var reason: String?

    public init(
        action: Action,
        tier: TierInstallState,
        coreRunning: Bool,
        blockers: [String] = [],
        reason: String? = nil
    ) {
        self.action = action
        self.tier = tier
        self.coreRunning = coreRunning
        self.blockers = blockers
        self.reason = reason
    }
}

/// Outcome of an executed `migrateCoreToUserAgent()` call. `plan` is the
/// pre-migration assessment, so a no-op success still reports the tier state.
public struct CoreMigrationResult: Codable, Equatable, Sendable {
    public var migrated: Bool
    public var plan: CoreMigrationPlan
    /// Observable core state after the call (unchanged for a no-op).
    public var coreState: CoreRunState
    public var corePID: Int32?

    public init(migrated: Bool, plan: CoreMigrationPlan, coreState: CoreRunState, corePID: Int32? = nil) {
        self.migrated = migrated
        self.plan = plan
        self.coreState = coreState
        self.corePID = corePID
    }
}

// MARK: - Dual-tier detection and migration

extension KumoController {
    /// Reports the installed tiers and the router's current core owner.
    ///
    /// Cheap enough for periodic UI refresh: it reads both managers' cached
    /// status (socket pings, no writes) and makes no core-lifecycle call.
    public func tierInstallState() -> TierInstallState {
        let root = currentServiceStatus()
        let agent = userAgentManager.status()
        let tunEnabled = currentTunEnabled()
        let decision = router.decideCoreBackend(tunEnabled: tunEnabled)

        let owner: TierInstallState.CoreOwner
        switch decision.backend {
        case .rootService: owner = .rootService
        case .userAgent: owner = .userAgent
        case .localSupervisor: owner = .localSupervisor
        case nil: owner = .unavailable
        }

        let installState: TierInstallState.InstallState
        switch (root.isInstalled, agent.isInstalled) {
        case (true, true): installState = .dual
        case (true, false): installState = .rootOnly
        case (false, true): installState = .userOnly
        case (false, false): installState = .none
        }

        return TierInstallState(
            installState: installState,
            coreOwner: owner,
            tunEnabled: tunEnabled,
            rootService: root,
            userAgent: agent,
            ownerUnavailableReason: decision.unavailableReason
        )
    }

    /// Non-mutating assessment behind `kumo agent migrate --dry-run`. Throws
    /// only when the running-core state cannot be read at all.
    public func coreMigrationPlan() throws -> CoreMigrationPlan {
        try migrationAssessment().plan
    }

    /// Moves a running, root-owned core to the user agent so it survives GUI
    /// quits without the privileged daemon owning it.
    ///
    /// Guards (refusal throws `KumoError.serviceUnavailable` naming the
    /// reason):
    /// - TUN enabled: the core must stay root-owned; disable TUN first.
    /// - User agent not installed: install it first; this call never installs.
    ///
    /// When the router selects the root daemon for a running core, the core is
    /// stopped on the root daemon, started on the user agent, and the root
    /// daemon restores it when the agent start fails
    /// (`transferCoreOwnership`). When no core is running — or the agent
    /// already owns it — this is a no-op success that only reports state.
    /// Running it again after a successful migration is therefore a no-op.
    @discardableResult
    public func migrateCoreToUserAgent() throws -> CoreMigrationResult {
        let (plan, preStatus) = try migrationAssessment()
        if let blocker = plan.blockers.first {
            throw KumoError.serviceUnavailable(blocker)
        }

        guard plan.action == .handoff else {
            return CoreMigrationResult(
                migrated: false,
                plan: plan,
                coreState: preStatus.state,
                corePID: preStatus.pid
            )
        }

        let started = try transferCoreOwnership(from: .rootService, to: .userAgent)
        routingLogger.info("Core ownership migrated from the root daemon to the user agent.")
        let postStatus = (try? status()) ?? started
        return CoreMigrationResult(
            migrated: true,
            plan: plan,
            coreState: postStatus.state,
            corePID: postStatus.pid
        )
    }

    /// Shared read used by the plan and the migration so both observe exactly
    /// the same tier state and running-core state.
    func migrationAssessment() throws -> (plan: CoreMigrationPlan, status: CoreStatus) {
        let tier = tierInstallState()
        let status = try status()
        let coreRunning = status.state == .running

        var blockers: [String] = []
        if tier.tunEnabled {
            blockers.append(
                "TUN is enabled, so the core must stay with Kumo Helper while TUN is active. Disable TUN before migrating the core to the user agent."
            )
        }
        if !tier.userAgent.isInstalled {
            blockers.append(
                "The Kumo agent is not installed. Install it first (`kumo agent install`), then retry the migration."
            )
        }

        var action = CoreMigrationPlan.Action.none
        var reason: String?
        if let blocker = blockers.first {
            reason = blocker
        } else if !coreRunning {
            reason = "No Mihomo core is running; nothing to hand over."
        } else {
            switch tier.coreOwner {
            case .rootService:
                action = .handoff
            case .userAgent:
                reason = "The user agent already owns the running core."
            case .localSupervisor:
                reason = "The running core belongs to a local Kumo process (direct mode), not to Kumo Helper; there is no socket-tier core to migrate."
            case .unavailable:
                reason = tier.ownerUnavailableReason
                    ?? "No runtime tier can own the core right now."
            }
        }

        return (
            CoreMigrationPlan(
                action: action,
                tier: tier,
                coreRunning: coreRunning,
                blockers: blockers,
                reason: reason
            ),
            status
        )
    }
}
