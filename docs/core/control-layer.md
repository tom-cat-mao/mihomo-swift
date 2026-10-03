# Core Control Layer

## Purpose

`KumoCoreKit` is the shared domain layer for the GUI, CLI, tests, and future service mode. It prevents the app from developing separate, inconsistent implementations for lifecycle control, profile generation, controller calls, and system proxy changes.

## Public Entry Point

`KumoController` is the high-level facade. It currently exposes:

- `status()`
- `currentProfile()`
- `profiles()`
- `setCurrentProfile(id:)`
- `coreCandidates()`
- `setCorePath(_:)`
- `installManagedCore()`
- `start(corePath:)`
- `stop()`
- `restart(corePath:)`
- `setMode(_:)`
- `proxyGroups()`
- `selectProxy(group:name:)`
- `testProxyDelay(proxy:testURL:)`
- `testGroupDelay(group:)`
- `refreshProfile(from:)`
- `importProfile(from:)`
- `profileContent(id:)`
- `profileProxyGroups(id:)` / `profileNodes(id:)` (memoized profile YAML parses)
- `updateProfile(...)`
- `deleteProfile(id:)`
- `refreshProfile(id:)`
- `refreshDueProfiles()`
- `coreConfiguration()`
- `rules()`
- `connections()`
- `recentLogs(limit:)` (tail-read; see `docs/operations/persistence-logging.md`)
- `setSystemProxy(_:dryRun:)`
- `dnsSettings()` / `updateDnsSettings(_:)` / `applyDnsSettings(_:)` / `setDnsEnabled(_:)`
- `snifferSettings()` / `updateSnifferSettings(_:)` / `applySnifferSettings(_:)` / `setSnifferEnabled(_:)`
- `updateTunSettings(_:)` / `applyTunSettings(_:)` / `setTunEnabled(_:)`
- `subStoreStatus()` / `updateSubStoreStatus(_:)` / `prepareSubStoreResources()`
- `exportBackup(to:)` / `importBackup(from:)`
- `checkAppUpdate(...)` / `downloadAppUpdate(...)` / `installAppUpdate(...)`
- `userPreferences()` / `updateUserPreferences(_:)`
- `installCLILink()` / `uninstallCLILink()`
- `prepareForAppTermination(policy:)` — best-effort shutdown entry point (see below)

This API is intentionally close to the CLI command vocabulary and the future service API.

## Runtime Tier Routing (Two-Tier Runtime, In Progress)

`KumoController` selects which process owns or runs the Mihomo core per
operation through an internal `BackendRouter`
(`Sources/KumoCoreKit/Service/BackendRouter.swift`). All existing public method
signatures stay stable; routing is not part of the public API.

| Current state | Backend |
| --- | --- |
| TUN enabled (per `state.json` runtime settings) | root LaunchDaemon (`io.kumo.KumoService`) |
| TUN disabled + user agent reachable | user LaunchAgent (`io.kumo.KumoAgent`, "kumod") |
| otherwise | local `CoreSupervisor` (historical default) |

- A TUN-enabled operation whose root daemon is unreachable fails with
  `KumoError.serviceUnavailable`. Kumo never silently runs a user-owned core
  while TUN is active, because that would strand TUN traffic. A privileged
  process (euid 0) may still own TUN locally.
- `status()` is read-only and degrades to the shared `state.json` plus pid
  recovery when the selected socket tier fails mid-call, so a live core owned
  by another tier is reported as running (for example after a GUI relaunch)
  instead of stopped.
- System proxy and TUN-status reads keep their historical root-or-local
  executor semantics; the router's reachability probe is the single source of
  truth for both.
- Reachability probes are injectable (`BackendReachability`) so routing and
  handoff tests run without sockets, launchd, or spawned processes.

The GUI/CLI wiring on top of this layer — installing the user agent, adopting
`prepareForAppTermination(policy:)` on quit, CLI tier selection — is follow-up
work. This layer provides the routing rule, the handoff, and the termination
policy API only.

## App Termination Policy

`prepareForAppTermination(policy:)` is the single best-effort shutdown entry
point. It never throws; every failed step is collected in
`ShutdownResult.diagnostics` and the returned status is the most recent
observable one.

- `.stopRuntime` (default) preserves today's `shutdownActiveRuntime()`
  behavior: disable Kumo-managed system proxy state, then stop the running core
  through whichever tier owns it.
- `.keepCoreAlive` disables nothing and stops nothing; it only reads the
  current status. It relies on the user agent (or root daemon) owning the core
  so the core keeps serving after the GUI quits. GUI wiring pending.

## Synchronous Facade, Serial App Executor

`KumoController` stays synchronous and `Sendable`. Its methods block the caller
on file IO, helper IPC, `networksetup` or Yams parsing, and the CLI and the
privileged helper (`KumoService`) call them directly on their own threads. That
facade is deliberately unchanged.

The GUI cannot afford that. It used to call the controller straight from
`@MainActor` code — on the 1 Hz status refresh, on every profile poll, on each
proxy reload and on each Inspect refresh — so every one of those stalled the
main thread. `KumoApp` therefore goes through `CoreRuntimeRunner`, a `public
actor` in `KumoCoreKit` that owns one controller and exposes the controller
surface the app needs as `async` methods:

- Awaiting a runner method runs the controller call on the actor's serial
  executor, off the main actor and serialized with every other runner call.
- It is not `Task.detached` per call: ordering between consecutive controller
  operations is load-bearing (write state, then read it back), and the actor
  preserves dispatch order.
- `KumoAppStore` still performs every `@Observable` assignment on the main
  actor, in the same order as before, so observers see the same values in the
  same sequence. Call sites that cannot await — SwiftUI `Binding` setters,
  `NSMenuItem` actions, App Intents — wrap the store method in a
  fire-and-forget `Task`.

The controller also memoizes the profile YAML parses the app repeats
(`profileProxyGroups(id:)`, `profileNodes(id:)`) through `ProfileParseCache`,
keyed on the profile file's `(fileURL, contentModificationDate, fileSize)`
identity, so an unchanged profile is parsed once instead of several times a
minute. `RuntimeConfigBuilder` is not a consumer of those cached values: it
builds its own YAML document from the raw profile string, so it cannot observe
or mutate a memoized entry.

## Internal Responsibilities

`KumoCoreKit` is split by responsibility:

- Models: `Profile`, `ProxyGroup`, `ProxyNode`, `CoreStatus`, `OutboundMode`, `CoreRuntimeSettings`, `TunSettings`, `DnsSettings`, `SnifferSettings`, `PolicyValue`, `FallbackFilterValue`.
- Configuration: profile loading, override management, and runtime config generation.
- Runtime: Mihomo process supervision, Sub-Store lifecycle, and core installation.
- Networking: Mihomo external-controller client and Sub-Store HTTP client.
- System: macOS system proxy command construction and execution, PAC server.
- Service: signed Unix socket transport for privileged helper IPC.
- Support: paths, state storage, shared errors, app updates, backups, and CLI link management.

## Design Rules

- Keep UI concerns out of `KumoCoreKit`.
- Keep `Process` and shell execution behind small wrappers.
- Keep dry-run paths available for tests and agent workflows.
- Keep error messages specific enough for UI and CLI display.
- Keep advanced GUI behavior behind `KumoController` so the CLI and future service mode can reuse it.

## Sparkle-Parity Growth Areas

The next alignment pass expands the facade in these areas:

- Runtime settings: controlled ports, LAN, log level, controller secret, IPv6, and Geo data settings.
- Providers: proxy provider and rule provider listing, refresh, and safe content preview.
- Rules: richer rule metadata and rule enable/disable operations.
- Logs: structured recent logs plus a live log event stream.
- Overrides: ordered YAML overrides first, followed by reviewed JavaScript transform support.
- Sub-Store: local service lifecycle and optional custom backend support.

## Future Compatibility

When a privileged service is introduced, `KumoController` should be able to switch from local implementations to service-backed implementations without changing GUI or CLI command semantics.
