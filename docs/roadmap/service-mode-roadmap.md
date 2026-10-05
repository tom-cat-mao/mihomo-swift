# Service Mode Roadmap

## Why Service Mode Exists

The first version can run without a privileged service. That keeps development simple and avoids asking for unnecessary permissions. Service mode becomes valuable when Kumo needs stronger lifecycle guarantees or privileged networking features.

## Reference Model

The Sparkle reference project uses a separate service process with:

- Unix socket communication
- Request signing
- Core start and stop endpoints
- Core event streams
- System proxy endpoints
- Fallback to non-service mode when service is unavailable

Kumo follows the same separation of concerns in Swift-native form. The helper
path uses administrator authorization and LaunchDaemon registration; it does
not use NetworkExtension or install a VPN configuration profile.

## Proposed API Shape

`KumoService` endpoints mirror current `KumoCoreKit` intent:

- `GET /status`
- `POST /core/start`
- `POST /core/stop`
- `POST /core/restart`
- `PATCH /core/mode`
- `PUT /core/proxies/{group}`
- `GET /core/events`
- `GET /sysproxy/status`
- `POST /sysproxy/enable`
- `POST /sysproxy/disable`
- `GET /service/status`
- `POST /service/install`
- `POST /service/uninstall`
- `GET /tun/status`
- `POST /tun/enable`
- `POST /tun/disable`

The GUI and CLI should keep their public command semantics unchanged.

## Authentication

The service does not trust arbitrary local clients. `KumoServiceRequestSigner`
defines the Swift-side canonical request and HMAC header shape used by the
Unix socket transport:

- A generated shared secret persisted in Kumo Application Support.
- Request timestamps and nonces.
- Request body hashing.
- A canonical signing string.

## Migration Strategy

1. Keep local `KumoCoreKit` implementations as the default.
2. Add service client protocols with the same high-level operations.
3. Introduce `KumoService` as an optional backend.
4. Keep TUN guarded by service availability: if no helper or privileged process
   is available, Kumo records the failure and rolls the TUN setting back.
5. Switch GUI and CLI to service-backed calls when service mode is enabled.
6. Preserve CLI output schemas.

## Remaining Helper Work

- Harden LaunchDaemon installation for notarized release artifacts.
- Improve automatic service repair and diagnostics.
- Expand proxy guard events and UI notifications.
- Move PAC hosting fully into the helper process for long-lived service mode.

The current implementation adds the service-mode model, signed endpoint
surface, CLI/UI status, administrator-authorized `KumoService` installation,
Unix socket request routing, service-backed core/system proxy/TUN control, and
TUN configuration generation. It intentionally does not silently install a
privileged daemon; installation remains an explicit, authorized user action.

## User-Level Agent Tier

The two-tier runtime adds a user-level LaunchAgent (`io.kumo.KumoAgent`,
"kumod") that owns the Mihomo core when TUN is off, so the GUI can quit while
the core keeps running. The root LaunchDaemon stays the TUN and privileged
operations tier; `BackendRouter` selects the tier per operation.

- The agent runs as the logged-in user, registers through `SMAppService.agent`
  in bundled builds, and falls back to `launchctl bootstrap gui/<uid>` with a
  generated `~/Library/LaunchAgents/io.kumo.KumoAgent.plist` for source-tree
  runs.
- It speaks the same signed Unix socket protocol and reuses the existing
  shared credentials file; only the socket path (`kumo-agent.sock`), log path
  (`logs/agent.log`) and launchd domain differ from the root daemon.
- `KumoService service` subcommands accept `--mode root|user` (default
  `root`); root-mode behavior is unchanged.
- The root LaunchDaemon stays installed for privileged operations (TUN,
  system proxy).

`Kumo.app` bundles the tier payload (`Contents/MacOS/KumoService` plus
`Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist`). Installation
validates the rendered plist against the current machine before
`SMAppService.agent` registration and falls back to a generated
`~/Library/LaunchAgents` plist plus `launchctl bootstrap`. Core routing, TUN
ownership handoff, the termination policy, and root-to-agent migration are
documented in [Control Layer](../core/control-layer.md) and
[ADR-005](../decisions/ADR-005-two-tier-runtime.md).

The agent is on demand, not permanently resident:

- The generated plist declares a launchd `Sockets` listener with
  `RunAtLoad=false` / `KeepAlive=false`, and `KumoService service run` adopts
  the activated descriptor with `launch_activate_socket` (falling back to
  binding the socket itself for manual/dev runs). launchd holds the endpoint
  and starts the agent on the first client connection.
- The agent exits by itself once `--idle-timeout <seconds>` (default 300)
  passes without a served client request and with no Mihomo core running.
  While a core is running it never idle-exits; root mode has no idle exit.
- `service install --mode user` accepts `--idle-timeout` and passes it into
  the generated plist's `ProgramArguments`.
- Lifecycle events (start, socket adopt/bind, observed core start/stop,
  idle-exit with reason) are appended to `logs/agent.log` in addition to
  stdout; the socket file is left in place on idle exit because launchd owns
  it.

Observed launchd behavior on the smoke host (Darwin 27): `bootstrap` starts a
`Sockets` job once even with `RunAtLoad=false` (reproduced with a minimal
non-Kumo job), and the idle timeout bounds that run like any other. launchd
also applies its ~10-second respawn throttle when a run is shorter than that
window, which can delay the next on-demand start by up to ~10s; with the
default 300-second idle timeout runs always outlive the throttle, and a
post-exit connection was served in ~0.1s in the smoke test.

## Status of Local Subsystems (Phase B)

Phase B brings several locally hosted subsystems into the app process,
without introducing the privileged service. Each is documented here so the
service-mode migration can absorb them later without scope surprises.

- **PAC mode is implemented** via `PACServer` (NWListener HTTP loopback) +
  `networksetup -setautoproxyurl`. When a privileged service exists, this
  listener should move into the service process and the front-end should
  request "PAC enabled" rather than hosting the listener directly.
- **Sub-Store local lifecycle is implemented in the app process** via
  `SubStoreSupervisor` (Node `Process` lifecycle + `logs/substore.log`).
  A future service tier should own this process so the GUI can be quit
  without killing Sub-Store. Sub-Store's UI is fully SwiftUI-native and talks to the
  backend over HTTP, so the service hand-off only needs to relocate the
  backend process, not any web frontend.
- **Open at Login** uses `SMAppService.mainApp`. Switching it to a
  `SMAppService.daemon`/`agent` registration so the service can run
  independently of the UI remains future work even though the bundled agent
  tier now exists.
- **Spotlight indexing** uses `CSSearchableIndex.default()` from the app
  process. This works without a service; only the data source has to move
  if profile state is later owned by the service.
- **App Intents** call back into `KumoAppStore`. Behind a service, these
  should hit the same JSON service endpoints documented above so intents
  keep working when the GUI is closed.
- **TUN mode** now has first-class settings in `CoreRuntimeSettings`. When
  enabled behind service availability, runtime config generation owns the
  `tun:` and required `dns:` blocks and the helper restarts Mihomo from the
  privileged backend. When service mode is unavailable, Kumo disables the
  requested TUN state and surfaces the helper requirement.
