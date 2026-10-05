# ADR-005: Two-Tier Runtime (User Agent and Root Daemon)

## Status

Accepted

## Context

Before this refactor the Mihomo core had a single owner per session: the GUI
or CLI process that started it (`CoreSupervisor`), or the privileged
`io.kumo.KumoService` LaunchDaemon when service mode was installed. Two
consequences followed:

1. **GUI lifetime is core lifetime.** Quitting the GUI stops the core by
   default (`shutdownActiveRuntime()`), so traffic stops with the window.
   Sparkle, the reference product, offers a lighter mode where the UI can quit
   while the proxy keeps serving; Kumo users expected the same.
2. **TUN forces root.** TUN requires a root-owned core, so the privileged
   daemon is the only tier that can own it while TUN is on. Every non-TUN
   operation therefore either ran inside the GUI/CLI process (no survival after
   quit) or required a permanently installed privileged daemon for simple
   start/stop.

The refactor needed a way to keep the core alive without a resident privileged
owner, without weakening the TUN rule, and without changing the public
`KumoController`, CLI, or UI command semantics.

## Decision

Split core ownership across two service tiers plus the historical in-process
supervisor, selected per operation by `BackendRouter`
(`Sources/KumoCoreKit/Service/BackendRouter.swift`):

1. **User tier — `kumod`.** A user LaunchAgent (`io.kumo.KumoAgent`) runs the
   same `KumoService` binary in `--mode user`, speaks the same signed Unix
   socket protocol with the same shared credentials file, and binds
   `kumo-agent.sock`. When TUN is off it owns the Mihomo core, so `Cmd+Q` no
   longer kills the core.
2. **Root tier — unchanged.** The privileged `io.kumo.KumoService`
   LaunchDaemon keeps owning the core whenever TUN is enabled and keeps
   brokering privileged operations (system proxy, TUN).
3. **Routing rule.** TUN on → root daemon (a privileged local process may
   still own TUN locally; otherwise the operation fails with
   `KumoError.serviceUnavailable` instead of stranding TUN traffic). TUN off +
   agent reachable → agent. TUN off + no agent + root daemon reachable → root
   daemon, preserving pre-agent service-mode semantics. Otherwise → local
   `CoreSupervisor`.
4. **On-demand agent, not resident.** The generated plist declares a launchd
   `Sockets` listener with `RunAtLoad=false` / `KeepAlive=false`. launchd owns
   the endpoint and starts the agent on the first client connection; the agent
   adopts the descriptor with `launch_activate_socket` (falling back to
   binding the socket for manual runs). It exits after `--idle-timeout`
   (default 300 s) with no served request and no running core, and never while
   a core is running.
5. **Termination policy.** `prepareForAppTermination(policy:)` is the single
   shutdown entry point. `.stopRuntime` is today's stop-everything behavior;
   `.keepCoreAlive` disables nothing and stops nothing, relying on the agent
   or root daemon owning the core. The GUI selects the policy from
   `UserPreferences.keepCoreRunningOnQuit` (Settings → General → Background).
6. **TUN ownership handoff restarts the core.** Enabling TUN while the agent
   owns a running core stops it through the agent and starts it through the
   root daemon; disabling TUN hands it back to the agent when one is
   reachable. The brief traffic gap from the restart is accepted. Every
   handoff has rollback: a failed target start restores the previous setting
   where applicable and restarts the core on the source tier, and the thrown
   error names the target failure plus each rollback outcome.
7. **Migration API.** `tierInstallState()` reports
   `none | rootOnly | userOnly | dual` plus the router's current core owner and
   the TUN state driving it; `coreMigrationPlan()` is the non-mutating
   assessment; `migrateCoreToUserAgent()` performs the root → agent handoff
   and refuses while TUN is enabled or the agent is not installed. The CLI
   exposes all of it through `kumo agent status|install|uninstall|migrate`.
   The app bundles the rendered LaunchAgent plist and validates it against the
   current machine before `SMAppService.agent` registration, falling back to a
   runtime-generated plist plus `launchctl bootstrap` when the bundle moved.

### Rationale

1. **Sparkle parity**: the core survives GUI quit without keeping the GUI
   resident.

2. **Least privilege**: the always-available tier runs as the logged-in user;
   root is involved only for TUN and protected system changes. Installing the
   privileged daemon remains an explicit, authorized action.

3. **One protocol**: both tiers speak the same signed socket protocol, so
   routing, handoff, and rollback are tier-agnostic and testable with injected
   reachability probes instead of live sockets and launchd jobs.

4. **Stable facade**: `KumoController`'s public method signatures and the CLI
   command surface are unchanged; routing is an internal decision.

## Alternatives Considered

### Keep the core GUI-resident (status quo)

Rejected. The core dies with the GUI by default, which is exactly the Sparkle
gap this refactor closes. Keeping the GUI process resident just to own the
core also fights the calm daily-use goal.

### Run every operation through the privileged daemon

Rejected. This would also survive GUI quit, but it makes the root daemon
mandatory for plain start/stop, requires an administrator prompt and a
privileged install for lightweight mode, and gives the root tier ownership of
a core that does not need root until TUN is enabled.

### `KeepAlive=true` / `RunAtLoad` for the user agent

Rejected in favor of launchd socket activation. An always-resident agent costs
memory and a login item for a capability that is only needed while traffic
flows. The measured cost of on-demand startup is a ~10 s launchd respawn
throttle when a run is shorter than the throttle window; with the default
300 s idle timeout, runs outlive the throttle and a post-exit connection was
served in ~0.1 s in the smoke test. The agent never idle-exits while a core is
running, so the throttle cannot interrupt active traffic.

### Extend the root daemon with the new write surface instead of a user tier

Deferred, not rejected: the root daemon's route table stays at
service/core/sysproxy/TUN routes. Extending it is tracked as a follow-up
(see Consequences) because it does not unblock lightweight quit.

## Consequences

### Positive

- The GUI can quit while the core keeps serving; the "Keep Mihomo running
  after quit" toggle and the Background Agent row make the state visible in
  Settings → General → Background.
- TUN stays correct by construction: a TUN-enabled operation fails rather than
  silently running a user-owned core.
- `kumo agent migrate` moves an existing root-owned core to the user tier
  without reinstalling or losing the running core, with idempotent no-op
  behavior and rollback on failure.
- The expanded CLI write surface (rules, providers, profile CRUD, DNS /
  Sniffer / TUN settings, sysproxy set, delay tests, `logs --follow`,
  `traffic --watch`) works against whichever tier owns the core, because core
  restarts route through `BackendRouter`.

### Negative

- TUN transitions restart the core, so enabling or disabling TUN exposes a
  short traffic gap. Accepted (matches Clash Verge Rev behavior).
- `.keepCoreAlive` is only durable when a socket tier owns the core. In direct
  mode the core is a child of the GUI process, so the preference cannot make
  it outlive quit; installing the agent (or the root daemon) is what makes the
  policy meaningful.
- The bundled LaunchAgent plist embeds the build machine's absolute paths.
  Installation parses and validates it against the current machine and falls
  back to a runtime-generated plist plus `launchctl bootstrap` when it does
  not match.

### Follow-ups (not this refactor)

- **Root-daemon route parity**: the daemon's signed-socket surface was not
  extended with the new write-surface or agent-management routes; those calls
  run in-process. A daemon-brokered equivalent remains backlog.
- **Sub-Store stays in the app process**: quitting the GUI still stops
  Sub-Store; moving it under `kumod` is backlog.
- **User-tier secret stays file-based** (`service-credentials.json`, `0600` in
  Application Support, same model as the root tier). Keychain migration is
  backlog; the HMAC layer is defense-in-depth under the same uid.
- **VM acceptance deferred**: `tart`-based verification of TUN and system
  proxy global effects (L2) remains manual user acceptance.

## Related

- `docs/core/control-layer.md`
- `docs/core/mihomo-runtime-controller.md`
- `docs/interfaces/cli-agent-control.md`
- `docs/operations/system-integration-permissions.md`
- `docs/roadmap/service-mode-roadmap.md`
- `docs/roadmap/two-tier-runtime-refactor.md`
- `Sources/KumoCoreKit/Service/BackendRouter.swift`
- `Sources/KumoCoreKit/Service/KumoUserAgentManager.swift`
- `Sources/KumoCoreKit/Service/KumoController+BackendRouting.swift`
- `Sources/KumoCoreKit/Service/KumoController+TierMigration.swift`
