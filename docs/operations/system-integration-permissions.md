# System Integration and Permissions

## App Bundle and Entitlements

Kumo ships as a real `.app` bundle generated from `project.yml` via XcodeGen
(`make generate`). The bundle pulls in:

- `Resources/KumoApp/Info.plist` — bundle metadata, `LSApplicationCategoryType`,
  `NSAppTransportSecurity` (allows local-network PAC), `NSServices` (Services
  menu), `CFBundleDocumentTypes` (`.yaml` profiles), `NSUserActivityTypes`
  (Spotlight handoff), and `NSAppleEventsUsageDescription` /
  `NSSystemAdministrationUsageDescription` (consent strings used when running
  `networksetup` and spawning the Mihomo / bundled Node Sub-Store processes).
- `Resources/KumoApp/KumoApp.entitlements` — `com.apple.security.app-sandbox`
  is **disabled** so that `networksetup` invocations and child processes
  (Mihomo core, Sub-Store backend/frontend listeners, PAC HTTP listener) keep working without a
  separate helper. `com.apple.security.network.client` and
  `com.apple.security.network.server` are enabled. Sandboxing remains a
  follow-up once helper-bundle / XPC architecture lands.

Build commands:

```bash
make generate    # xcodegen generate -> Kumo.xcodeproj (gitignored)
make app         # xcodebuild Debug -> build/Build/Products/Debug/Kumo.app
make app-release # xcodebuild Release
make dev         # build + open Kumo.app
make dev-cli     # legacy swift run KumoApp without bundle (no Spotlight / Intents)
```

## System Proxy

`SystemProxyController` runs macOS `networksetup` commands and now branches on
the `SystemProxyMode` carried by `SystemProxyConfiguration`:

- `manual` mode configures web, secure web, SOCKS firewall proxies, plus the
  bypass list, and explicitly turns auto-proxy state off.
- `pac` mode boots a local `PACServer` (loopback `NWListener` HTTP that
  responds with the user's PAC script as
  `application/x-ns-proxy-autoconfig`), then runs `-setautoproxyurl
  http://127.0.0.1:<port>/proxy.pac` and `-setautoproxystate on`, while
  turning manual web/secure/socks off.
- `setEnabled(false)` stops the PAC server and turns both manual and PAC
  states off.

`setSystemProxy(_:dryRun:)` is `async` — dry-run mode skips the listener and
returns the would-be commands for inspection (used by the CLI and tests).

Before enabling system proxy, Kumo now verifies that the target
`host:mixed-port` is accepting local TCP connections. This prevents macOS from
being pointed at a stale or failed listener. After applying `networksetup`
commands, Kumo reads the OS proxy state back and only marks the feature enabled
when manual or PAC settings match the requested mode.

## Command Line Tool Symlink

`Kumo.app/Contents/Helpers/kumo` is the source of truth for the bundled CLI;
it is copied into the app bundle by the `Copy Kumo CLI` post-build script in
`project.yml` (and the equivalent `cp` step in `Makefile`). The helper path is
intentional: macOS volumes are case-insensitive by default, so dropping the
CLI as `Contents/MacOS/kumo` would silently overwrite the GUI main binary
`Contents/MacOS/Kumo`. The first-run onboarding sheet and Settings > General >
Command Line Tool both use `CLILinkInstaller` to manage a symlink at
`/usr/local/bin/kumo` that points at the bundled binary.

`CLILinkInstaller` reuses the `osascript ... with administrator privileges`
pattern used by `KumoServiceManager` because `/usr/local/bin` is not writable
for ordinary users. Install runs `/bin/ln -sfn <bundled> /usr/local/bin/kumo`
inside the elevated shell call; uninstall runs `/bin/rm -f` and refuses to
delete a symlink that does not point at the bundled CLI, so unrelated CLI
shims are not affected. macOS will request administrator authorization once
per operation, the same way the Kumo Helper install does, and the prompt is
separate from any VPN configuration prompt.

The target path is reported through `KumoController.cliLinkStatus()` so the
UI and CLI can show whether the symlink is installed, points elsewhere, or is
shadowed by a regular file. There is no automatic update — running the CLI
installer again repoints the symlink at whatever `kumo` ships inside the
current `Kumo.app`.

## LaunchAgent (Open at Login)

`KumoAppDelegate` keeps `SMAppService.mainApp` in sync with
`UserPreferences.launchAtLogin` whenever the app launches. The Settings
"Preferences" tab toggles the same preference and registers/unregisters
through `SMAppService`. Registration only succeeds when `Kumo.app` lives in
`/Applications` (macOS launch services requirement).

## Bundled User Agent (kumod)

For the two-tier runtime, `Kumo.app` also carries the unprivileged user-tier
("kumod") payload:

- `Contents/MacOS/KumoService` — the same helper binary the privileged tier
  uses; launchd starts it as `KumoService service run --mode user`.
- `Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist` — the LaunchAgent
  registration `SMAppService.agent(plistName:)` requires at that exact path.
  The `Copy Kumo Agent LaunchAgent` post-build phase in `project.yml` renders
  it from `Resources/KumoApp/LaunchAgents/io.kumo.KumoAgent.plist` with
  `Scripts/prepare_agent_launchagent.sh`, so the paths are absolute and the
  keys match `KumoUserAgentManager.launchAgentPlist(...)`, which generates the
  equivalent plist for source-tree and dev installs.

The bundled plist keeps the on-demand contract: a launchd `Sockets` listener
owns `kumo-agent.sock` with mode `0600` and starts the agent on the first
client connection. `RunAtLoad` and `KeepAlive` stay false, so the agent is not
resident at login and exits again after its idle timeout.

`KumoUserAgentManager.install()` prefers `SMAppService.agent` when the app runs
from a bundle and falls back to writing the generated plist to
`~/Library/LaunchAgents` plus `launchctl bootstrap` when ServiceManagement
declines. Registration follows the same `/Applications` rule as
`SMAppService.mainApp`, and the bundled plist is rendered with the build
machine's home directory and the built bundle path. A `Kumo.app` installed
elsewhere therefore cannot use the bundled plist as-is; it installs the agent
through the launchctl fallback, which resolves the current machine's paths at
install time. Rendering the bundled plist per user at install time (instead of
build time) is follow-up work in `Sources/`.

The rendered plist and the helper are in place before Xcode signs the bundle,
so both stay covered by the app's code signature; the helper is copied and
chmodded exactly like the pre-existing `Contents/MacOS/KumoService` embedding,
with no separate signing step.

## Dock Badge

While the app is running, a 1 s timer in `KumoAppDelegate` writes
`NSApp.dockTile.badgeLabel` from the live `KumoAppStore.connections.count`,
so the user sees connection volume even when the main window is hidden.

## Spotlight

`SpotlightIndexer` indexes profile summaries (name + source) into the default
`CSSearchableIndex` on launch and after profile refreshes. Each entry uses
the profile id as `uniqueIdentifier`, and `NSUserActivityTypes` declares
`io.kumo.KumoApp.openProfile`. Tapping a Spotlight result returns the user
to Kumo and selects the matching profile via `KumoAppContext.handleUserActivity`.

## Services Menu

`Info.plist` registers a single Services entry — "Import Profile to Kumo" —
that targets `importProfileURL(_:userData:error:)` on the AppDelegate. Any
text or URL string sent through Services becomes a profile import attempt
via `KumoAppStore.importRemoteProfile(urlString:useProxy:)`.

## App Intents

`KumoIntents.swift` exposes five intents that surface in Shortcuts, Siri,
and Spotlight:

- `StartKumoIntent` / `StopKumoIntent`
- `RefreshKumoIntent`
- `SetKumoModeIntent` (with `KumoModeChoice` enum mirroring `OutboundMode`)
- `ToggleSystemProxyIntent`

Phrases are wired through `KumoShortcutsProvider`. Each intent resolves the
live `KumoAppStore` via `KumoAppContext.shared.store`, so intent
side-effects stay consistent with the SwiftUI UI.

## Dry Run

`setSystemProxy(_:dryRun:)` (now `async`) still supports dry-run for unit
tests, CLI previews, agent safety, and debugging network service names.
Dry-run returns the exact commands without executing them and without
binding the PAC listener.

## Current Assumptions

Kumo can still store a manual network service name, but new default system
proxy settings prefer the active route interface by resolving
`route -n get default` through `networksetup -listnetworkserviceorder`.
This avoids writing proxy settings to `Wi-Fi` when the active service is
Ethernet, USB tethering, or another macOS network service.

When enabling system proxy outside dry-run, Kumo captures the previous
proxy state for the selected service. The disable path turns Kumo-managed
manual and auto-proxy states off; a later service-backed pass should
restore exact previous values from the snapshot.

Foreground app quit uses the same disable path before allowing termination by
default. The SwiftUI app delegate returns `.terminateLater`, asks
`KumoAppStore` to disable Kumo-managed system proxy state and stop Mihomo, then
replies to AppKit that termination may continue. This prevents macOS from
keeping manual or PAC proxy settings pointed at `127.0.0.1:<mixed-port>` after
Kumo's UI is gone. When `Keep Mihomo running after quit` is enabled, the store
asks for `.keepCoreAlive` instead: the proxy state and the agent- or
daemon-owned core are deliberately left running so traffic continues without the
GUI.

## Runtime Tier Migration

The two-tier runtime can hand a running core from the privileged
`io.kumo.KumoService` LaunchDaemon to the unprivileged `io.kumo.KumoAgent`
LaunchAgent so the core keeps serving without the privileged daemon owning it.

- Migration refuses while TUN is enabled: TUN requires a root-owned core, so
  disable TUN first (`kumo tun disable`). It also refuses until the agent is
  installed; the caller installs it (`kumo agent install`) and retries. Both
  refusals name the reason.
- When the root daemon owns a running core, the core is stopped there and
  started by the agent, with the root daemon restored if the agent start fails.
  With no running core — or when the agent already owns it — migration is a
  no-op that only reports state.
- `kumo agent migrate [--dry-run] [--json]` exposes this; `--dry-run` reports
  the installed tiers, the router's current core owner, and any guard refusals
  without touching launchd, sockets, or the core.
- The pre-update core stop stays tier-aware: the app calls
  `KumoController.stop()`, which routes to whichever tier owns the core, so an
  agent-owned core is stopped before the bundle is replaced.

## Permissions

Kumo now has the model and command surface for service mode, including signed
service requests, service status, TUN status, and a `KumoService` helper target.
This follows the Sparkle and Clash Verge Rev model: macOS asks for administrator
authorization when Kumo installs or repairs the helper, but Kumo does **not**
register a NetworkExtension or VPN profile. The "Allow VPN Configuration"
system prompt is therefore not expected for System Proxy or Mihomo TUN mode.

Until the helper or a privileged process is available, TUN enable requests fail
with a visible service-mode error instead of leaving the UI in a misleading
"On" state. Once installed, the helper owns privileged operations such as
starting Mihomo for TUN and applying guarded system proxy changes.
On foreground app quit (with `Keep Mihomo running after quit` off, the default),
Kumo stops the helper-owned Mihomo process rather than uninstalling the helper.
Stopping Mihomo is the cleanup boundary for the active TUN route and
Mihomo-managed DNS interception; the user's persisted TUN preference remains
available for the next explicit start. With the preference on, the helper-owned
core keeps running with that TUN route and DNS interception intact.

## Advanced Features

The following remain hardening work after the first service-backed path:

- System proxy guard and auto-restore
- Privileged helper repair UX
- LaunchDaemon management hardening and notarized distribution

## Future Work

- Restore exact previous proxy settings from the captured snapshot.
- Add a proxy guard in service mode.
- Harden the signed privileged helper installer for TUN and protected system
  changes, including notarized app distribution.
- Adopt App Sandbox + helper-bundle separation so `networksetup` invocations
  and child processes can run from a sandboxed front-end.
