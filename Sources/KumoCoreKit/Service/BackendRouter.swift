import Darwin
import Foundation

/// Which runtime tier owns (or takes) the Mihomo core for one operation.
///
/// The two-tier runtime splits core ownership three ways:
///
/// - `rootService`: the privileged LaunchDaemon (`io.kumo.KumoService`).
///   Required whenever TUN is enabled, because TUN needs root.
/// - `userAgent`: the user LaunchAgent (`io.kumo.KumoAgent`, "kumod"). Owns
///   the core when TUN is off so the core survives GUI quit.
/// - `localSupervisor`: the GUI/CLI process itself (`CoreSupervisor`), the
///   historical default when neither socket tier applies.
enum RuntimeBackend: String, CaseIterable, Sendable {
    case rootService
    case userAgent
    case localSupervisor

    var displayName: String {
        switch self {
        case .rootService: "Kumo Helper"
        case .userAgent: "Kumo agent"
        case .localSupervisor: "this process"
        }
    }

    /// The ownership-record value for a core this tier successfully starts.
    var ownerTier: RuntimeOwnerTier {
        switch self {
        case .rootService: .rootService
        case .userAgent: .userAgent
        case .localSupervisor: .localSupervisor
        }
    }
}

/// Outcome of one routing decision.
enum CoreBackendDecision: Equatable, Sendable {
    case backend(RuntimeBackend)

    /// TUN is enabled but no privileged executor (root daemon or a privileged
    /// local process) is reachable. Mutating operations must fail with this
    /// reason instead of silently running a user-owned core, which would
    /// strand TUN traffic.
    case unavailable(String)

    var backend: RuntimeBackend? {
        switch self {
        case .backend(let backend): backend
        case .unavailable: nil
        }
    }

    var unavailableReason: String? {
        switch self {
        case .unavailable(let reason): reason
        case .backend: nil
        }
    }
}

/// Injectable reachability probes for the tier decisions. Production probes
/// ping the signed sockets and consult euid; tests inject closures so every
/// tier combination can be exercised without sockets or launchd.
struct BackendReachability: Sendable {
    var rootService: @Sendable () -> Bool
    var userAgent: @Sendable () -> Bool
    /// True when the calling process itself can manage privileged networking
    /// (euid 0) even though the root daemon is unreachable — the historical
    /// privileged direct-mode fallback, which does not strand TUN.
    var privilegedLocalProcess: @Sendable () -> Bool

    init(
        rootService: @escaping @Sendable () -> Bool,
        userAgent: @escaping @Sendable () -> Bool,
        privilegedLocalProcess: @escaping @Sendable () -> Bool = { false }
    ) {
        self.rootService = rootService
        self.userAgent = userAgent
        self.privilegedLocalProcess = privilegedLocalProcess
    }

    /// Live probes: the root probe mirrors `KumoServiceManager.status()`
    /// (socket presence when privileged, signed ping otherwise), the agent
    /// probe pings `kumo-agent.sock` through its signed client, and the local
    /// probe is euid 0.
    static func live(paths: KumoPaths, useServiceBackend: Bool) -> BackendReachability {
        let serviceManager = KumoServiceManager(paths: paths)
        let userAgentManager = KumoUserAgentManager(paths: paths)
        return BackendReachability(
            rootService: { useServiceBackend && serviceManager.status().isRunning },
            userAgent: { useServiceBackend && userAgentManager.status().isRunning },
            privilegedLocalProcess: { geteuid() == 0 }
        )
    }
}

/// Selects the runtime tier per operation.
///
/// Routing rule:
///
/// - TUN enabled → root daemon. Unreachable → `unavailable`; the operation
///   fails rather than falling back to a user-owned core.
/// - TUN disabled + user agent reachable → user agent.
/// - TUN disabled + root daemon reachable → root daemon. This preserves the
///   pre-agent service-mode semantics: an existing daemon-owned core stays
///   visible and controllable until it is migrated to the user agent.
/// - Otherwise → local supervisor (the historical default).
///
/// `allowsServiceBackend == false` short-circuits every decision to the local
/// supervisor: `KumoService` constructs its own controller that way, so a tier
/// daemon never routes back into a socket tier.
struct BackendRouter: Sendable {
    var reachability: BackendReachability
    var allowsServiceBackend: Bool

    init(reachability: BackendReachability, allowsServiceBackend: Bool = true) {
        self.reachability = reachability
        self.allowsServiceBackend = allowsServiceBackend
    }

    func decideCoreBackend(tunEnabled: Bool) -> CoreBackendDecision {
        guard allowsServiceBackend else {
            return .backend(.localSupervisor)
        }

        if tunEnabled {
            if reachability.rootService() {
                return .backend(.rootService)
            }
            if reachability.privilegedLocalProcess() {
                return .backend(.localSupervisor)
            }
            return .unavailable(
                "TUN is enabled but Kumo Helper is not reachable. Kumo will not run the core as a user process while TUN is active because that would strand TUN traffic; reinstall or repair Kumo Helper, then retry."
            )
        }

        if reachability.userAgent() {
            return .backend(.userAgent)
        }
        if reachability.rootService() {
            return .backend(.rootService)
        }
        return .backend(.localSupervisor)
    }

    /// Executor for privileged operations (system proxy, TUN requests): the
    /// root daemon when reachable, otherwise the calling process. The user
    /// agent never performs privileged operations, so it is not a candidate.
    func privilegedBackend() -> RuntimeBackend {
        guard allowsServiceBackend, reachability.rootService() else {
            return .localSupervisor
        }
        return .rootService
    }
}

/// Injectable per-tier core lifecycle operations. Production code talks to the
/// real tiers (signed sockets or `CoreSupervisor`); tests inject closures so
/// handoff success and rollback can be exercised without sockets or spawns.
struct TierOperationsOverride: Sendable {
    var stop: @Sendable (RuntimeBackend) throws -> CoreStatus
    var start: @Sendable (RuntimeBackend) throws -> CoreStatus
}
