# Mihomo Runtime and Controller

## Runtime Model

Kumo manages a Mihomo core executable. The core can come from:

- A path passed to the CLI with `--core`.
- The `KUMO_MIHOMO_PATH` environment variable.
- A bundled `mihomo` resource.
- Common Homebrew or system paths.

The current implementation starts Mihomo with a generated work directory. The generated `config.yaml` contains Kumo-controlled controller and proxy settings, and the supervisor also passes the controller endpoint with Mihomo's `-ext-ctl` flag plus `-secret` when a secret is configured. This keeps the UI and CLI controller surface reachable even when a profile or Mihomo build treats controller YAML differently from listener settings.

## Process Supervision

`CoreSupervisor` handles:

- Preparing application support directories.
- Writing the runtime configuration.
- Probing the controller port so a second core is never spawned onto a busy
  control endpoint.
- Rotating `logs/core.log` before each launch.
- Starting Mihomo with `Process`.
- Recording the process identifier in state and `work/core.pid`.
- Stopping recorded processes with a graceful signal escalation path.
- Detecting stale process identifiers without mistaking foreign-owned live
  processes for dead ones.
- Recording runtime lifecycle events.

Stop uses both the persisted status PID and the `work/core.pid` fallback, then
escalates through `SIGINT`, `SIGTERM`, and `SIGKILL`. For child processes
started by the current process, `CoreSupervisor` uses `waitpid(..., WNOHANG)`
while waiting so exited children are reaped instead of being mistaken for
still-running zombie processes. When a stop succeeds, the PID file and stored
PID are cleared together. Status checks also consult `work/core.pid`, so Kumo
can recover a running state when the JSON state lost its PID but the managed
core is still alive.

### Liveness and ownership

Liveness is decided by `kill(pid, 0)` plus errno:

- `0` — the process exists and the caller may signal it.
- `ESRCH` — the process is gone. This is the only outcome that proves death.
- `EPERM` — the process exists but is owned by another user, which is the
  normal case for a core started as root by the privileged helper while the
  app or CLI runs unprivileged. `CoreSupervisor` treats this as **alive**.

Because EPERM counts as alive, stale-pid cleanup (`core.stale_pid`) only fires
on genuine death, so an unprivileged status check can no longer clear the PID
record of a live root-owned core and let a later `start()` double-launch. When
a stop is attempted against a process the caller cannot signal,
`terminateProcess` fails fast on EPERM instead of waiting through the signal
escalation timeouts, and `stop()` reports a failed state that names the
unreachable PID. The PID record is kept rather than cleared, so the CLI does
not print `Mihomo core stopped.` for a core that is still running; stopping
such a core requires the privileged helper or an administrator.

### Single-instance guard

Before clearing the PID record and spawning, `CoreSupervisor.start()` probes
the configured external-controller address (`endpoint.host:endpoint.port`,
for example `127.0.0.1:9097`) with a blocking TCP connect capped at about one
second. Any successful connection — or, equivalently, any HTTP response on
`GET /version` — means another process already owns the controller port, and
`start()` throws `KumoError.controllerPortInUse` without spawning anything.
Every spawn path funnels through `CoreSupervisor.start()`, so the app, the CLI,
and the privileged helper all share the guard. A process that is already
running but no longer recorded is reported instead of being joined by a second
core.

### Core log rotation

Each launch writes core stdout and stderr to a fresh `logs/core.log`: if the
existing file is non-empty it is first renamed to
`logs/core-<yyyyMMdd-HHmmss>.log` (local time). A previously started core that
is still running keeps writing to its renamed file, so lines from concurrent
cores no longer interleave in `core.log`.

This local supervision path is still available as the fallback. When Kumo
Helper is installed and reachable, `KumoController` routes start, stop,
restart, system proxy, and TUN operations through the signed Unix socket
service backend so the privileged helper owns Mihomo. Helper-routed start and
restart requests wait for Mihomo's controller endpoint to answer before
returning, so callers do not observe a running process whose control surface
is still unavailable. `kumo start` performs the same `GET /version` readiness
wait as the app and the daemon; if the controller never answers, the command
fails with the reason and the `logs/core.log` path instead of reporting a
plain success.

`KumoAppDelegate.applicationShouldTerminate(_:)` delays app termination while
`KumoAppStore.prepareForTermination()` runs
`KumoController.shutdownActiveRuntime()`. The shutdown is best-effort and
log-and-continue: it disables Kumo-managed system proxy state, then stops the
running Mihomo core through the helper when it is reachable or through the
local supervisor otherwise. Each step has a fallback — a synchronous
`networksetup` invocation backs up the async/helper proxy disable, and a
direct `CoreSupervisor.stop()` backs up the helper-routed core stop — so a
single hung IPC call does not leave Mihomo or the user's proxy settings in a
broken state. Diagnostics from every failed step are collected into a
`ShutdownResult` and surfaced via `errorMessage`; the post-shutdown UI state
reset always runs, even when every step failed. This mirrors Sparkle's
`Promise.all([triggerSysProxy(false), stopCore()])` + `will-quit` →
`disableSysProxySync()` pattern.

The AppDelegate races `prepareForTermination` against a 5 s timeout so a
hung helper-IPC stop or stuck `networksetup` invocation cannot keep AppKit
in `.terminateLater` forever; this is the Swift analogue of Sparkle's
SIGINT → SIGTERM → SIGKILL ladder (capped at +6 s in `process-control.ts`).

The helper daemon may remain installed and reachable after app quit, but it
must not leave a helper-owned Mihomo process, TUN route, or DNS interception
active. Stopping Mihomo is the cleanup boundary for the active TUN route
and Mihomo-managed DNS interception.

## TUN Runtime Settings

`CoreRuntimeSettings` carries `TunSettings`. When TUN is enabled and service
mode is available, `RuntimeConfigBuilder` removes profile-provided `tun`
top-level blocks and appends Kumo-controlled TUN settings:

- `tun.enable`
- `tun.stack`
- `tun.auto-route`
- `tun.auto-redirect`
- `tun.auto-detect-interface`
- `tun.strict-route`
- `tun.disable-icmp-forwarding`
- `tun.dns-hijack`
- `tun.route-exclude-address`
- `tun.mtu`
- `tun.device` (macOS only, when prefixed with `utun`)

On macOS, Kumo only writes a configured TUN device name when it already starts
with `utun`, matching the platform's virtual interface naming rules. If no
privileged helper or privileged process is available, TUN enable requests are
rejected and the stored state is rolled back before Mihomo is restarted.

When Kumo Helper is running, `POST /tun/enable` updates the same runtime
settings, rewrites the controlled config, restarts the helper-owned Mihomo
process, waits for the controller to become ready, and reports the resulting
`TunStatus`. The macOS authorization involved is helper installation/repair,
not a NetworkExtension VPN configuration prompt.

## DNS Runtime Settings

`CoreRuntimeSettings` carries `DnsSettings` independently of TUN. When DNS is
enabled, `RuntimeConfigBuilder` removes profile-provided `dns` and `hosts`
top-level blocks and appends Kumo-controlled DNS settings:

- `dns.enable`
- `dns.listen`
- `dns.ipv6`
- `dns.ipv6-timeout`
- `dns.prefer-h3`
- `dns.enhanced-mode`
- `dns.fake-ip-range`
- `dns.fake-ip-range6`
- `dns.fake-ip-filter`
- `dns.fake-ip-filter-mode`
- `dns.use-hosts`
- `dns.use-system-hosts`
- `dns.respect-rules`
- `dns.default-nameserver`
- `dns.nameserver`
- `dns.fallback`
- `dns.fallback-filter`
- `dns.proxy-server-nameserver`
- `dns.direct-nameserver`
- `dns.direct-nameserver-follow-policy`
- `dns.nameserver-policy`
- `dns.proxy-server-nameserver-policy`
- `dns.cache-algorithm`

DNS settings are also surfaced through the Mihomo controller (`GET /configs`)
and can be patched at runtime (`PATCH /configs`). However, because DNS
configuration is structurally significant, applying DNS changes through the UI
restarts the core rather than patching piecemeal, matching Mihomo's expectation
that DNS structure changes are loaded from the generated runtime YAML.

### Hosts

Mihomo's `hosts` key is a top-level configuration block, not nested under `dns`.
Kumo stores `hosts` inside `DnsSettings` for UI convenience (users edit hosts
alongside DNS settings in the Configure view), but `RuntimeConfigBuilder` emits
`hosts` as a separate top-level block. The `hosts` key is only stripped from
user profiles when the user has actually configured hosts in the Kumo UI;
otherwise, profile-provided hosts are preserved.

## Sniffer Runtime Settings

`CoreRuntimeSettings` carries `SnifferSettings` independently of TUN and DNS.
When Sniffer is enabled, `RuntimeConfigBuilder` removes profile-provided
`sniffer` top-level blocks and appends Kumo-controlled Sniffer settings:

- `sniffer.enable`
- `sniffer.parse-pure-ip`
- `sniffer.force-dns-mapping`
- `sniffer.override-destination`
- `sniffer.sniff.HTTP` (with `ports` and `override-destination`)
- `sniffer.sniff.TLS` (with `ports`)
- `sniffer.sniff.QUIC` (with `ports`)
- `sniffer.skip-domain`
- `sniffer.force-domain`
- `sniffer.skip-dst-address`
- `sniffer.skip-src-address`

Sniffer changes are applied through core restart, matching the TUN and DNS
application pattern.

## Controller Client

`MihomoControllerClient` wraps the Mihomo external-controller API:

- `GET /version`
- `GET /configs`
- `PATCH /configs`
- `GET /proxies`
- `PUT /proxies/{group}`
- `GET /proxies/{proxy}/delay`
- `GET /rules`
- `GET /connections`
- `DELETE /connections`
- `DELETE /connections/{id}`
- `GET /traffic` over WebSocket
- `GET /memory` over WebSocket

It maps proxy groups into `ProxyGroup`, proxy names into `ProxyNode`, rules into `RuleEntry`, and connections into `ConnectionEntry`.

## Sparkle-Parity Controller Surface

The following external-controller endpoints are planned for the Configure and Inspect pages:

- `PATCH /rules/disable`
- `GET /providers/proxies`
- `PUT /providers/proxies/{name}`
- `GET /providers/rules`
- `PUT /providers/rules/{name}`
- `POST /upgrade/geo`
- `GET /logs` over WebSocket or an equivalent streaming transport

## Current Transport

Local mode uses HTTP through `URLSession` to talk to Mihomo's external
controller. Service mode uses Kumo's signed Unix socket transport to ask
`KumoService` to perform privileged lifecycle operations, while the helper-owned
Mihomo process still exposes its normal external-controller API.

## Error Handling

Controller failures are surfaced as `KumoError.controllerResponse(status, body)` when the response is not successful. UI and CLI callers should display the resulting message without hiding the HTTP status.

## Future Work

- Add resilient reconnect policies for event streams.
- Add restart policies.
- Add provider initialization progress.
- Add provider update and preview APIs.
- Add structured log streaming and cache limits.
