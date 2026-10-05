# Sparkle Parity Roadmap

Kumo tracks Sparkle as a product-capability reference, not as an Electron
implementation target. The goal is to keep Kumo native to macOS while reaching
equivalent coverage for Mihomo control, system integration, diagnostics,
updates, and backup workflows.

## Status Legend

- `implemented`: usable through shared `KumoCoreKit` behavior.
- `partial`: a visible or persisted surface exists, but parity is incomplete.
- `planned`: no complete implementation yet, but the architecture has a place
  for it.
- `deferred`: intentionally postponed until a prerequisite is stable.

## Capability Matrix

| Area | Capability | Kumo Status | Primary Kumo Owner | Acceptance Point |
| --- | --- | --- | --- | --- |
| Core | Local Mihomo process start/stop/restart | implemented | `CoreSupervisor` | `kumo start --json`, `kumo stop --json`, stale PID recovery, and the single-instance controller-port guard work. |
| Core | Managed Mihomo core install | partial | `CoreInstaller` | Stable and preview channels can install, verify, cache, and report versions. |
| Core | Startup readiness states | partial | `CoreSupervisor` | UI can distinguish launched, controller ready, providers ready, and failed. |
| Core | Graceful shutdown with timeout escalation | implemented | `CoreSupervisor` | Stop attempts graceful termination before force kill, uses a PID file fallback, and persists failures; app quit runs through `prepareForAppTermination(policy:)` with a 5 s gate and optional keep-core-alive. |
| Runtime | Structured runtime config merge | implemented | `RuntimeConfigBuilder` | Profile, overrides, and Kumo-owned keys merge with deterministic precedence. |
| Runtime | Config cleanup and normalization | implemented | `RuntimeConfigBuilder` | Profile-provided controlled keys are removed, and empty/default fields are omitted before writing runtime YAML. |
| Profiles | Local profile import and edit | implemented | `ProfileRepository` | Local YAML can be imported, edited, selected, and deleted safely. |
| Profiles | Remote profile refresh | implemented | `ProfileRepository` | Remote subscriptions refresh manually and on due intervals. |
| Profiles | Subscription metadata retention | partial | `ProfileRepository` | Headers persist name, home URL, update interval, user info, UA, and fingerprint. |
| Overrides | Ordered YAML overrides | implemented | `OverrideRepository` | Global and profile-scoped YAML overrides persist, apply in documented order, and are covered by tests. |
| Overrides | JavaScript transforms | deferred | `OverrideRepository` | Requires a reviewed sandbox strategy before enablement. |
| Controller | Proxy groups and selection | implemented | `MihomoControllerClient` | Groups load, filter hidden entries, and allow node selection. |
| Controller | Outbound mode switching | implemented | `KumoAppStore` / `MihomoControllerClient` | Rule / Global / Direct changes persist locally, PATCH Mihomo `/configs`, close existing connections, and refresh proxy groups without blocking the Start / Stop toolbar action. |
| Controller | Rules, connections, providers, geo updates | partial | `MihomoControllerClient` | Inspect and Configure pages expose controller actions without direct UI clients. |
| Controller | Traffic, memory, logs, and lifecycle events | partial | `MihomoControllerClient` | Event streams use bounded caches and survive transient disconnects. |
| CLI | Stable agent-friendly JSON commands | partial | `KumoCLI` | Every command has `--json`, stable envelopes, and deterministic exit codes. |
| System Proxy | Manual macOS system proxy | implemented | `SystemProxyController` | Dry-run and real commands configure web, secure web, and SOCKS proxy. |
| System Proxy | Active service detection and restore | partial | `SystemProxyController` | Kumo detects the active network service by default route; restoring exact previous proxy settings from the captured snapshot is still open. |
| System Proxy | PAC hosting and guard | partial | `SystemProxyController` / `KumoService` | PAC hosting ships in the app process (`PACServer` + `networksetup -setautoproxyurl`); the proxy guard and helper-hosted PAC listener remain open. |
| Service | Privileged service backend | implemented | `KumoService` | The root LaunchDaemon handles TUN and privileged operations, the user LaunchAgent handles TUN-off core ownership, and `BackendRouter` selects the tier per command without public command changes; both serve the CLI while the GUI is closed. |
| Service | Signed local service requests | implemented | `KumoService` | Requests use shared key material, timestamps, nonces, and body hashing on both tiers, with signing tests. |
| Sub-Store | Persisted configuration | implemented | `SubStoreManager` | Status, local resource version, backend port, cron settings, proxy mode, LAN mode, and custom backend settings persist. |
| Sub-Store | Local lifecycle management | implemented | `SubStoreManager` / `SubStoreSupervisor` | Bundled Node sidecar + `sub-store.bundle.js` are prepared on demand; Kumo starts, stops, and restarts the backend. |
| Sub-Store | Native management UI | implemented | `KumoApp.SubStoreView` / `SubStoreClient` | SwiftUI surfaces subscriptions, collections, files, modules, artifacts, archives, tokens, settings, and logs by talking to the backend over HTTP. |
| Resources | Proxy/rule provider management | partial | `MihomoControllerClient` | Providers list, update, and show useful metadata in Configure. |
| Diagnostics | Connections and logs inspection | partial | `MihomoControllerClient` / `KumoAppStore` | Active/closed connections, close actions, filtering, and live logs are available. |
| Backup | Export/import local state | planned | `KumoCoreKit` | Profiles, overrides, settings, Sub-Store status, and service settings round-trip. |
| Updates | App update channel and installer | implemented | `AppUpdateManager` / `AppUpdateInstaller` | Stable/beta feeds, checksum-verified downloads, and the detached installer helper ship; automatic replacement requires a writable parent directory. |
| UI | Native Daily / Inspect / Configure IA | implemented | `KumoApp` | Advanced features remain secondary to the daily connection workflow. |
| UI | Sparkle-level advanced controls | partial | `KumoAppStore` / Views | Proxies, connections, rules, logs, profiles, and settings reach feature parity. |
| Quality | CoreKit unit tests | partial | `KumoCoreTests` | Runtime, profile, override, state, proxy, and controller mapping tests pass. |
| Quality | CLI, service, and UI store tests | partial | Tests | CLI parsing, JSON envelope, service signing, and tier-routing tests ship; UI store state transitions remain a coverage gap. |

## Implementation Order

1. Harden service mode: notarized helper distribution, automatic repair, and
   proxy-guard events.
2. Design and review the JavaScript override sandbox.
3. Add core lifecycle event streams and JSON schemas for automation consumers.
4. Extend root-daemon route parity, service-side log streaming, and
   helper-hosted PAC hosting.

## Non-Goals

- Do not port Sparkle's Electron renderer or giant IPC surface.
- Do not add JavaScript overrides until sandboxing and audit behavior are
  explicitly designed.
- Do not move TUN, PAC guard, or privileged networking into the primary daily
  workflow; they stay behind Configure and explicit helper installation.
