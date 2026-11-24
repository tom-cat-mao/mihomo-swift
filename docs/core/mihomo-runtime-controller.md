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
- Building a candidate runtime configuration, validating it with `mihomo -t`,
  and atomically installing it only after validation succeeds.
- Probing both mixed proxy and controller ports before spawning.
- Rotating `logs/core.log` before each launch.
- Starting Mihomo with `Process` and observing `terminationHandler`.
- Recording the process identifier and kernel start time in state and
  `work/core.pid`.
- Stopping recorded processes with identity-checked graceful signal escalation.
- Detecting dead, zombie, foreign, and PID-reused records without signalling a
  process whose identity does not match.
- Recording expected and unexpected exits plus runtime lifecycle events.

Stop uses both the persisted status PID and the `work/core.pid` fallback, then
escalates through `SIGINT`, `SIGTERM`, and `SIGKILL`. For child processes
started by the current process, `CoreSupervisor` uses `waitpid(..., WNOHANG)`
while waiting so exited children are reaped instead of being mistaken for
still-running zombie processes. When a stop succeeds, the PID file and stored
PID are cleared together. Status checks also consult `work/core.pid`, so Kumo
can recover a running state when the JSON state lost its PID but the managed
core's identity still matches.

### Liveness, identity, and exit records

`kill(pid, 0)` is only an existence check. `CoreProcessInspector` additionally
reads `proc_pidinfo` for the kernel start time and zombie state, and uses
`proc_pidpath` for legacy executable-path adoption. `CoreStatus.processStartTime`
stores the precise timestamp numerically so JSON persistence does not lose the
fractional seconds needed for identity comparison. A reused PID, a missing
identity, or a zombie is never treated as permission to send a signal. EPERM
still means that a foreign-owned process exists, but an unverifiable identity
cannot be stopped locally; the request must go through its owning tier.

Every supervised launch records `CoreStatus.lastExit` with time, pid, exit code
or signal, `expected`, and a message. Expected stops become `stopped` and clear
ownership. Unexpected exits become `failed`, retain `ownerTier` for status and
notification consumers, append the latest core fatal log line when available,
and emit `core.exit_unexpected`. The same supervisor runs inside local mode,
the user agent, and the root daemon, so all three owners share this behavior
without changing `BackendRouter` or TUN ownership routing.

Unexpected exits have bounded automatic recovery: at most three attempts with
2/5/15 second backoff, reset after a launch remains stable for five minutes.
An explicit start/stop cancels pending recovery. Expected stops, configuration
preflight failures, and port conflicts do not schedule another attempt.
Recovery events are `core.recovery_scheduled`, `core.recovered`,
`core.recovery_failed`, and `core.recovery_exhausted`.

### State ownership and bookkeeping tolerance

The privileged helper runs as root, so it — not the app or CLI — owns every
app-support file it creates. On a fresh service-mode install that left
`state.json`, `logs/runtime-events.jsonl` and `work/*` as `root:staff 0644`,
after which every non-root bookkeeping write failed with `EACCES` and
`kumo start` reported a false failure for a core that was actually up
(Issue #3). Three rules keep that from recurring:

- **The helper repairs ownership.** `AppSupportOwnershipRepair` chowns the
  app-support root and every non-symlinked entry beneath it to the authorized
  uid (from `--authorized-uid`) and that user's primary gid (`getpwuid`). The
  daemon runs it once at startup — the upgrade path for installs already in the
  broken state — and again after every request that can write app-support
  state, including the pid-recovery writes a plain `/status` read can trigger.
  The walk is a single bounded pass, never chowns or follows symlinks, and
  skips `/Library/PrivilegedHelperTools/io.kumo.KumoService` and the launchd
  plist, which stay root-owned. The call is a no-op unless the process is root,
  so an unprivileged caller can invoke it unconditionally.
- **Caller-side bookkeeping is best-effort in service mode.** Runtime events go
  through a non-throwing append that logs a warning and drops the row when the
  file cannot be written — the event trail is diagnostic, never a precondition
  for managing the core. The same holds for the `controllerReady` bookkeeping
  `waitForControllerReady()` performs after a helper-routed start: the helper's
  `state.json` is authoritative, and a denied caller-side write must not turn a
  ready core into a failed `start`.
- **Direct mode still fails loudly.** Without a helper there is no other
  writer, so the supervisor's own record stays load-bearing: `state.json` and
  the `work/core.pid` record (and the readiness update that follows them) still
  throw when they cannot be persisted. A silently unrecorded pid would mean a
  core the next `status()` or `stop()` cannot find or stop.

### Single-instance guard and port diagnostics

Before clearing the PID record and spawning, `CoreSupervisor.start()` checks
both the mixed listener and the external-controller address with real local
TCP bind probes. The mixed probe uses `0.0.0.0` when Allow LAN is enabled and
`127.0.0.1` otherwise. Both probes enable `SO_REUSEADDR`, matching Mihomo's Go
listener: a recently closed controller's `TIME_WAIT` tail must remain reusable
across restart, while an actively listening socket still fails the bind. A
shared mixed/controller port is also a conflict even when nothing else occupies
it. Every spawn path funnels through this guard, so the app, CLI, root daemon
and user agent all reject the launch before spawning a second core.

A failure throws `KumoError.portConflicts`, whose entries carry `role`, `host`,
`port`, optional `pid` / `processName`, and `suggestedPort`. The small
`LocalPortInspector` wrapper owns the bind probes, `/usr/sbin/lsof` listener
lookup and suggestion scan. Process fields stay absent when macOS cannot
identify the holder; Kumo never guesses one. Suggestions avoid both configured
ports and the other role's suggestion.

`KumoController.portConflicts()` is the read-only check. Only an explicit
`resolvePortConflicts()` call, `start(resolvePortConflicts: true)`, CLI
`kumo start --resolve-ports`, or the GUI's **Use Free Ports** confirmation may
persist new ports. Resolution updates `runtimeSettings.mixedPort`,
`proxyPorts.mixedPort`, the controller endpoint and stored system-proxy port
together. After the controller becomes ready, an already-enabled system proxy
is reapplied through the existing system-proxy controller so it targets the
new mixed listener. A normal start never changes ports silently. Service
start requests carry the same opt-in flag, and a 409 response preserves the
structured conflict array rather than flattening it into an error string.

### Configuration validation and hot reload

Every start and required restart builds a separate candidate file and runs
`mihomo -t -d <work> -f <candidate>` with a 15-second bound. A timed-out
validator is terminated and waited on so the child is reaped rather than left
as a zombie. Validation output is preserved in
`KumoError.configurationValidationFailed`, including the core's real fatal
message. The existing `work/config.yaml` is replaced atomically only after
success; restart preflight runs before stopping the old core.

`KumoController.reloadRuntimeConfiguration()` applies the same transaction to a
running core with `MihomoControllerClient.reloadConfiguration(path:)`, which
sends `PUT /configs?force=true`. `activateProfile(id:)`, current-profile YAML
edits, current-profile deletion, subscription refresh, and the
`create/change/remove/reorder` override APIs snapshot their repository state
first. Metadata-only updates, non-current edits, and non-current deletion do
not request a reload. A failed validation or reload restores profile bodies,
metadata, `current.txt`, override bodies/metadata, and the previous runtime
file as applicable. After an ambiguous transport failure Kumo also offers the
previous file back to the still-running core. The two-tier owner and TUN routing
are not changed by hot reload.

The same supervisor exposes `install:false` validation for `config validate`.
That path runs the real core against a unique temporary work directory, does
not append runtime events, and never installs or temporarily rewrites
`work/config.yaml`. `diffConfiguration(profileYAML:)` only builds in memory and
returns a stable unified diff against the last installed file.

`applyConfiguration(profileYAML:)` wraps the existing profile transaction with
a pending durable pre-apply point. Promotion happens only after validation,
installation, and any forced hot reload succeed. `rollbackConfiguration()`
restores the newest committed point and consumes it only after its own preflight
and hot reload succeed; failure restores the pre-rollback state and retains the
point. State restoration is limited to configuration inputs, preserving current
process identity/owner/readiness/exit and system-proxy observations. Committed
history is bounded to 10 private snapshots.

### Core log rotation

Each launch writes core stdout and stderr to a fresh `logs/core.log`: if the
existing file is non-empty it is first renamed to
`logs/core-<yyyyMMdd-HHmmss>.log` (local time). A previously started core that
is still running keeps writing to its renamed file, so lines from concurrent
cores no longer interleave in `core.log`.

This local supervision path is still available as the fallback. `KumoController`
selects the core's owner per operation through `BackendRouter`
(`Sources/KumoCoreKit/Service/BackendRouter.swift`):

- **TUN enabled** (per `state.json` runtime settings) → the privileged root
  daemon. If the root daemon is unreachable, start/stop/restart fail with
  `KumoError.serviceUnavailable`; Kumo never silently runs the core as a user
  process while TUN is active, because that would strand TUN traffic. A
  privileged process (euid 0) may own TUN locally.
- **TUN disabled + user agent reachable** → the user LaunchAgent
  (`io.kumo.KumoAgent`), so the core survives GUI quit.
- **TUN disabled + no agent + root daemon reachable** → the root daemon,
  preserving pre-agent service-mode semantics so an existing daemon-owned core
  stays visible and controllable until it is migrated.
- **Otherwise** → the local `CoreSupervisor` (historical default).

`status()` routes through the selected tier when it answers and otherwise
falls back to the shared `state.json` plus pid recovery, so a core owned by
another tier is reported as running (for example after a GUI relaunch) instead
of stopped. System proxy and TUN-status reads keep their root-or-local
executor semantics, using the same reachability probe as the router. Helper-
routed start and restart requests wait for Mihomo's controller endpoint to
answer before returning, so callers do not observe a running process whose
control surface is still unavailable. `kumo start` performs the same
`GET /version` readiness wait as the app and the daemon; if the controller
never answers, the command fails with the reason and the `logs/core.log` path
instead of reporting a plain success.

### Core ownership handoff (two-tier runtime)

TUN transitions move the core between tiers instead of leaving it on the wrong
owner:

- Enabling TUN while the user agent owns a running core stops the core through
  the agent, persists the TUN setting, and starts it through the root daemon
  (root-owned). Stopping and starting exposes a short traffic gap while the
  new core initializes.
- Disabling TUN while the root daemon owns a running core hands the core back
  to the user agent when the agent is reachable (stop via root, start via
  agent), so a later GUI quit does not kill it. When no agent is reachable the
  root daemon restarts its own core with TUN disabled.
- Every handoff has rollback: if the target tier fails to start, the previous
  setting is restored where applicable and the core is restarted on the source
  tier; the thrown error names the target failure and any rollback problem.
- The existing guard is unchanged: TUN enable without a reachable privileged
  tier fails and rolls the stored setting back.

### Core ownership record

`CoreStatus.ownerTier` records which tier owns the running core
(`rootService`, `userAgent`, or `localSupervisor`), so ownership transitions
are observable state instead of an inference from `BackendRouter`
reachability — which cannot tell a root-owned core from an agent-owned one
once both tiers are installed. Every successful start stamps the tier that
launched the core: the local supervisor stamps itself, the root daemon and the
user agent stamp their own tier through their internal controllers, and
`transferCoreOwnership` leaves the target tier's record on the core. A
successful stop (including `shutdownActiveRuntime`) clears the record; a
failed stop keeps it, because the core is still running. The field is additive
on the wire: a state written before the record loads with `ownerTier == nil`,
a nil record is omitted from the JSON, and a tier string from a newer build
decodes as `.unknown` instead of failing the whole read.

Read paths prefer the record and fall back to routing inference only when it
is missing or unknown (legacy states): `tierInstallState()` reports the
recorded owner, so `kumo agent migrate --dry-run` and
`migrateCoreToUserAgent()` still see a root-owned core after a just-installed
agent makes routing prefer itself, and the agent install guard consults the
record before its process probe. The guard only refuses while TUN pins the
core to Kumo Helper, and names the working remedy: disable TUN, retry the
install, then run `kumo agent migrate`. With TUN off the install is the first
step of that recovery; the guard records the root ownership it proved
(best-effort when the state file is not writable) so the migration reads the
record instead of the routing decision.

The GUI manages the user agent from Settings → General → Background
(`KumoUserAgentManager` via `KumoAppStore`) and picks the termination policy on
quit through `UserPreferences.keepCoreRunningOnQuit`; the CLI exposes the same
manager through `kumo agent status|install|uninstall|migrate`, where
`kumo agent migrate` performs the root-to-agent ownership handoff.

The old shutdown path is now expressed through
`prepareForAppTermination(policy:)`, which never throws and collects failures
in `ShutdownResult.diagnostics`:

- `.stopRuntime` (default) preserves `shutdownActiveRuntime()`:
  `KumoAppDelegate.applicationShouldTerminate(_:)` delays app termination
  while `KumoAppStore.prepareForTermination()` runs it. The shutdown is
  best-effort and log-and-continue: it disables Kumo-managed system proxy
  state, then stops the running Mihomo core through the owning tier when it is
  reachable or through the local supervisor otherwise. Each step has a
  fallback — a synchronous `networksetup` invocation backs up the async/helper
  proxy disable, and a direct `CoreSupervisor.stop()` backs up the
  helper-routed core stop — so a single hung IPC call does not leave Mihomo or
  the user's proxy settings in a broken state.
- `.keepCoreAlive` disables nothing and stops nothing; it only reads the
  current status. It relies on the user agent (or root daemon) owning the core,
  which is the policy the two-tier runtime exists for. The GUI selects it when
  the `Keep Mihomo running after quit` preference is on.

Diagnostics from every failed step are collected into a `ShutdownResult` and
surfaced via `errorMessage`; the post-shutdown UI state reset always runs, even
when every step failed. This mirrors Sparkle's
`Promise.all([triggerSysProxy(false), stopCore()])` + `will-quit` →
`disableSysProxySync()` pattern.

The AppDelegate races `prepareForTermination` against a 5 s timeout so a
hung helper-IPC stop or stuck `networksetup` invocation cannot keep AppKit
in `.terminateLater` forever; this is the Swift analogue of Sparkle's
SIGINT → SIGTERM → SIGKILL ladder (capped at +6 s in `process-control.ts`).

The helper daemon may remain installed and reachable after app quit, but under
`.stopRuntime` it must not leave a helper-owned Mihomo process, TUN route, or
DNS interception active. Stopping Mihomo is the cleanup boundary for the active
TUN route and Mihomo-managed DNS interception. Under `.keepCoreAlive` the
agent/root-owned core and the Kumo-managed system proxy are deliberately left
running so traffic keeps flowing after the GUI quits.

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

`tun.stack` accepts `mixed`, `gvisor`, `system`, and `mips`. New settings
default to `mips`; state written before MIPS support that has no `stack` field
still decodes as `mixed`, and all existing explicit stack values are retained.
The UI and CLI help note that MIPS requires Mihomo 1.19.32 or later, and the
CLI rejects unknown stack values instead of silently normalizing them.

On macOS, Kumo only writes a configured TUN device name when it already starts
with `utun`, matching the platform's virtual interface naming rules. If no
privileged helper or privileged process is available, TUN enable requests are
rejected and the stored state is rolled back before Mihomo is restarted.

When Kumo Helper is running, `POST /tun/enable` updates the same runtime
settings, rewrites the controlled config, restarts the helper-owned Mihomo
process, waits for the controller to become ready, and reports the resulting
`TunStatus`. In the two-tier runtime, enabling TUN while the user agent owns
the core first performs the ownership handoff described above, driven by the
GUI toggle and by `kumo tun enable`. The macOS authorization involved is
helper installation/repair, not a NetworkExtension VPN configuration prompt.

## DNS Runtime Settings

`CoreRuntimeSettings` carries `DnsSettings` independently of TUN. Its `source`
selects ownership of the top-level `dns` block: `kumo` (the default) or
`profile`. State written before the selector existed decodes without `source`
as `kumo`, so upgrades retain their existing generated DNS configuration.

With `kumo` ownership and Kumo DNS enabled, `RuntimeConfigBuilder` removes the
profile-provided `dns` block and emits the complete normalized Kumo mapping.
When Kumo DNS is disabled, it preserves the profile's `dns` block as before and
emits no Kumo DNS block. The enabled Kumo mapping includes:

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

With effective `profile` ownership, the builder preserves the current
profile's `dns` mapping verbatim after active overrides have been applied. It
does not parse, normalize, or reconstruct that mapping through `DnsSettings`.
`KumoController.currentProfileDeclaresDNS()` checks this merged profile, so an
active override can supply or remove the declaration.

A requested `profile` source without a merged `dns` declaration is a runtime
fallback, not a source-switch failure: the stored source remains `profile`, but
ownership resolves to Kumo for the generated runtime. The GUI reports this state
and keeps the Kumo fields editable. In contrast, an explicit `setDnsSource(_:)`
or DNS apply that fails validation or restart returns its error; it is not
silently presented as the missing-declaration fallback.

Source changes use `KumoController.setDnsSource(_:)`. `applyDnsSettings(_:)`
routes a source-only change through the same operation. A running core is
restarted so its configuration comes from the generated YAML. DNS structure
and source changes are not applied through piecemeal `PATCH /configs` calls.
Scalar runtime PATCH generation retains the existing Kumo-owned DNS payload
when Kumo DNS is enabled, but omits `dns` whenever the stored source is
`profile`, so unrelated changes cannot replace profile-owned DNS.

### Hosts

Mihomo's `hosts` key is a top-level configuration block, not nested under `dns`.
Kumo stores `hosts` inside `DnsSettings` for UI convenience, but
`RuntimeConfigBuilder` emits it as a separate top-level block. Hosts ownership
is orthogonal to the DNS source in both modes: non-empty Kumo hosts replace the
profile's top-level `hosts`; when Kumo hosts are empty, profile hosts are
preserved. The GUI therefore keeps the hosts editor available while profile DNS
is effective and submits hosts-only changes without replacing profile DNS.

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
- `GET /group/{group}/delay`
- `GET /proxies/{proxy}/delay`
- `GET /rules`
- `PATCH /rules/disable`
- `GET /providers/proxies`
- `PUT /providers/proxies/{name}`
- `GET /providers/rules`
- `PUT /providers/rules/{name}`
- `POST /upgrade/geo`
- `GET /connections`
- `DELETE /connections`
- `DELETE /connections/{id}`
- `GET /traffic` over WebSocket
- `GET /logs` over WebSocket
- `GET /memory` over WebSocket

It maps proxy groups into `ProxyGroup`, proxy names into `ProxyNode`, rules into `RuleEntry`, and connections into `ConnectionEntry`.

### Delay testing

Group tests prefer `GET /group/{group}/delay`. Only an HTTP 404, 405, or 501
response (an unsupported batch endpoint) selects the per-node fallback; the
fallback runs at most eight requests concurrently. Other HTTP, decoding, and
transport failures fail the group request instead of producing apparently
successful nodes. Dynamic URL components are encoded as one path segment using
the RFC 3986 unreserved set, so a slash inside a group or proxy name becomes
`%2F`, not a path separator or a double-encoded `%252F`.

`ProxyNode.delay` remains compatible with existing CLI consumers. The additive
`delayStatus` (`success`, `timeout`, `missing`, `error`, or `stale`) and
`delayError` fields distinguish the current outcome:

- A current success keeps its measured milliseconds; a current timeout keeps
  `delay == 0`. A current error has no delay and carries the actual HTTP or
  transport detail. Historical values never fill a failed current result.
- A delay read from `/proxies` history is `stale`, not a new measurement.
- A group member absent from the `/proxies` dictionary is `missing`; fallback
  sends no request for that member.

Single-proxy `proxyDelay` still throws non-2xx responses as
`KumoError.controllerResponse(status, body)`. The fallback catches per-node
errors only to attach them to that node; it never converts a batch-controller
failure into a successful group result.

## Sparkle-Parity Controller Surface

The Configure and Inspect pages use these additional external-controller
endpoints through `MihomoControllerClient` (`rules()`,
`setRuleEnabled(index:isEnabled:)`, `updateProxyProvider(name:)`,
`updateRuleProvider(name:)`, `upgradeGeoData()`, `logStream(level:)`), and the
CLI exposes the same operations (`kumo rules`, `kumo providers update`,
`kumo logs --follow`):

- `PATCH /rules/disable`
- `GET /providers/proxies`
- `PUT /providers/proxies/{name}`
- `GET /providers/rules`
- `PUT /providers/rules/{name}`
- `POST /upgrade/geo`
- `GET /logs` over WebSocket

## Current Transport

Local mode uses HTTP through a dedicated ephemeral `URLSession` whose proxy
dictionary is explicitly empty, so controller requests never traverse the
system HTTP, HTTPS, or SOCKS proxy. Tests can still inject a mocked session.
Service mode uses Kumo's signed Unix socket transport to ask `KumoService` to
perform privileged lifecycle operations, while the helper-owned Mihomo process
still exposes its normal external-controller API.

## Error Handling

Controller failures are surfaced as `KumoError.controllerResponse(status, body)` when the response is not successful. UI and CLI callers should display the resulting message without hiding the HTTP status.

## Future Work

- Add resilient reconnect policies for event streams.
- Add provider initialization progress.
- Add provider content preview APIs (listing and update already ship).
- Add cache limits for live log streaming.
