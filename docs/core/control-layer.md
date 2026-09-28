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

This API is intentionally close to the CLI command vocabulary and the future service API.

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
