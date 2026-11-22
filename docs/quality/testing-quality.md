# Testing and Quality

## Current Tests

The first test suite covers:

- Runtime config generation, including TUN MIPS YAML and legacy stack decoding.
- Ordered YAML/JavaScript overrides: successful transforms, array edits,
  missing `main`, non-object results, exceptions, real timeout termination,
  sandbox API limits, mixed-format ordering, and failure without partial writes.
- Mixed/controller port occupation, holder metadata, free-port suggestions,
  same-port collision avoidance, explicit resolution, recently closed `TIME_WAIT`
  connections versus active listeners, and the default no-silent-port-change
  guarantee across local and socket-tier starts.
- Core state persistence.
- System proxy command construction in dry-run mode.
- System proxy ownership with in-memory `networksetup` state: endpoint/PAC/bypass
  conflicts, service switching, takeover, external clear, manual/automatic
  Reclaim, safe stop/quit/guardian cleanup, and legacy Codable decoding.
- Mihomo controller response mapping with mocked URL loading.
- Delay testing through `MockURLProtocol`: batch success, unsupported-endpoint
  fallback, the eight-request concurrency ceiling (asynchronous mock responses),
  404/408/503/504 behavior, single-segment slash encoding, missing `/proxies`
  references, stale history, no old-delay reuse, and single-proxy HTTP errors.
- Backup export/import round trips.
- Service request signing.
- Agent protocol discovery: every runnable command has exactly one capabilities
  descriptor, dry-run/validate/rollback claims stay accurate, every prompt page
  and intent resolves, and every prompt step references a registered command.
- Configuration topology: missing groups/nodes/providers/rule sets, nested and
  dynamic groups, logical-rule comma parsing, active paths, generated stopped
  previews, hidden GLOBAL selections, and stable Codable/CLI output.
- CLI argument parsing, JSON envelope stability, color/log rendering rules, and
  npm-style help behavior.
- CLI command behavior: profile refresh dedupe, refresh-by-id, and
  `--use-proxy`; profile metadata update and YAML edit with pre-read backfill;
  offline profile group/node previews; runtime config get/set/secret
  validation; transactional override CRUD with preflight/hot-reload semantics;
  GUI preferences; the CLI link; provider `--all`; batch connection close; and
  the read-only Sub-Store content surface.
- Profile refresh metadata: remote-URL dedupe refreshes the matching profile
  in place, and `refreshDueProfiles` preserves Sub-Store profile metadata.
- Dev-instance environment overrides (`KUMO_APP_SUPPORT_DIR`,
  `KUMO_AGENT_LABEL`) and user-agent label plumbing into the generated plist.
- Two-tier runtime: routing decisions across TUN/agent/root/local, TUN
  ownership handoff and rollback, the app termination policy, root-to-agent
  migration guards, tier socket behavior, and the user-agent manager's launchd
  plist and idle policy.
- Runtime failure safety: expected/unexpected exits, exit codes and fatal log
  propagation, zombie/PID-reuse rejection, mixed/controller port conflicts,
  bounded 2/5/15-second recovery and the five-minute stability reset.
- Configuration transactions: `mihomo -t` candidate validation, forced full
  hot reload, profile/current-id/subscription/override rollback, preservation
  of the last known-good runtime config, and preflight before required restarts.
- Legacy profile mutation closure: current-profile edit preserves the running
  pid and old YAML on invalid input, valid edits hot-reload, metadata-only and
  non-current edits do not reload, current deletion hot-reloads the next
  profile, and failed deletion restores the deleted profile and selection.
- Explicit configuration closure: recursive proof that diff/validate change no
  application-support files, stable CLI JSON, successful apply snapshot commit,
  invalid apply without a successful point, bounded 10-point history, rollback
  content restoration and retry after failure, and preservation of running
  pid/owner/readiness/lastExit plus system-proxy observations.
- App-level behavior (`Tests/KumoAppTests/`): quit-path sidecar termination,
  termination policy mapping, startup store attach for App Intents, update-install
  flow including tier version-stamp repair prompts, `lastExit` notification
  baselining/deduplication with expected-stop suppression, and delay-presentation
  colors for current, stale and legacy success/timeout values.

These tests target `KumoCoreKit` because that layer carries the most important shared behavior.

## Testing Layers

Runtime verification is layered by isolation, cheapest first. Higher layers are
manual/opt-in and never replace L0.

| Layer | What it proves | Where it runs | Entry point |
|-------|----------------|---------------|-------------|
| L0 | Unit behavior: core kit, signing, launchd plists, idle policy | CI / local `swift test` | `swift test` |
| L1 | The agent tier installs, activates on demand, idles out and relaunches on this host, hermetically | Owner's Mac, disjoint dev label + `/tmp` app-support | `Scripts/dev/agent-smoke.sh` |
| L2 | Root daemon, system proxy and TUN on a disposable VM | Tart VM | `Scripts/dev/tart-l2-smoke.sh` |
| L3 | Production migration (real label, real app-support) | Owner-gated, manual | existing install flows |

### L0 — Unit / CI

```bash
swift test
```

On a Command Line Tools-only machine (no Xcode) build through the CLT gate:
`KUMO_CLT_BUILD=1 swift build`. XCTest is CI-only — CLT installs do not ship
`XCTest.framework`, so `swift test` cannot run locally there.

`make test` wraps `xcodebuild -scheme Kumo-Package` and requires the generated
`Kumo.xcodeproj`, so run `make generate` first; `make swift-test` is the
SwiftPM path.

### L1 — Dev instance on this host

`Scripts/dev/agent-instance.sh` manages a fully isolated instance of the
user-level agent tier: default label `io.kumo.KumoAgent.dev` and app-support
`~/Library/Application Support/KumoDev`, so it can never collide with the
production install. It refuses the production label/path even when overridden.

```bash
Scripts/dev/agent-instance.sh install     # build if needed + register
Scripts/dev/agent-instance.sh status      # signed status (starts on demand)
Scripts/dev/agent-instance.sh logs [-f]   # tail the dev agent log
Scripts/dev/agent-instance.sh uninstall   # bootout + remove plist/socket
```

`Scripts/dev/agent-smoke.sh` is the hermetic end-to-end check: fresh `/tmp`
app-support → install → socket `0600` → signed ping 200 → idle self-exit →
on-demand relaunch (timings printed) → uninstall → assert everything removed.
It refuses to run unless `KUMO_APP_SUPPORT_DIR` (under `/tmp`) and
`KUMO_AGENT_LABEL` (non-production) are set, and trap-cleans on failure.
With the smoke's short idle timeout, the relaunch timing includes launchd's
~10 s spawn throttle because the previous agent run was shorter than the
throttle window; the production 300 s idle timeout does not trip it.

```bash
KUMO_APP_SUPPORT_DIR=/tmp/kumo-agent-smoke \
KUMO_AGENT_LABEL=io.kumo.KumoAgent.dev \
Scripts/dev/agent-smoke.sh
```

Both scripts drive the same opt-in env overrides the binaries understand:
`KUMO_APP_SUPPORT_DIR` overrides the default app-support root when no explicit
directory is injected, and `KUMO_AGENT_LABEL` overrides the user-agent launchd
label (plist name, launchctl job, plist `EnvironmentVariables`). Unset, blank
or invalid values keep production behavior byte-identical. The root daemon
label (`io.kumo.KumoService`) has no override yet; root-tier dev instances are
L2/L3 territory.

### L2 — Disposable VM (Tart)

`Scripts/dev/tart-l2-smoke.sh` is the hermetic root/system-proxy/TUN acceptance
entry point. It builds the release CLI and helper, resolves an existing Mihomo
binary, creates a uniquely named clone, waits for SSH, installs the real root
LaunchDaemon, runs the guest assertions, collects detailed JSON results, and
removes the clone after both success and failure. It never modifies the host's
application support, launchd jobs or `/Applications`.

```bash
Scripts/dev/tart-l2-smoke.sh
```

The default base is the NJU mirror of `cirruslabs/macos-tahoe-base:latest`, with
the image's `admin`/`admin` credentials. Override `KUMO_TART_BASE_VM`,
`KUMO_TART_VM_USER`, `KUMO_TART_VM_PASSWORD` and `KUMO_MIHOMO_PATH` as needed.
`KUMO_L2_SKIP_BUILD=1` reuses release binaries; `KUMO_TART_GRAPHICS=1` shows the
Tart window instead of running headlessly. Logs and guest JSON are retained
under the ignored `build/l2-acceptance/` directory.

On 2026-11-22 the automated entry point passed with Tart 2.37.0, a macOS 26.6.2
arm64 guest and Mihomo 1.19.32:

- The real LaunchDaemon installed and ran, the signed socket became reachable,
  and the core reported `rootService` ownership.
- System proxy apply/disable and HTTP traversal passed; an external endpoint
  change produced `takenOver`, Reclaim restored `owned`, and disable cleaned up.
- New TUN defaults used MIPS. Enabling TUN created the `198.18.0.1` split routes
  on `utun4` and HTTPS traversal returned 200; disabling it removed those routes
  and preserved direct connectivity.
- Invalid `config apply` input was rejected without changing the running PID.
  Valid apply and rollback hot-reloaded with the same PID and working TUN.
- A real `SIGKILL` recorded signal 9, scheduled recovery attempt 1 after 2
  seconds, started a new PID and restored TUN HTTPS traversal.
- Restarting the root LaunchDaemon preserved the running core PID and network.
- Core stop and helper uninstall removed the guest runtime and daemon files.

The automated script invokes the helper's underlying privileged install command
directly. A separate visible Tart GUI run on the same date covered the user-facing
install surface:

- The generated DMG mounted and its checksum verified; Finder copied the arm64
  app to `/Applications`, onboarding completed, and the installed path launched.
- Clicking **Install / Repair Service** displayed the real macOS administrator
  authorization dialog. Accepting it installed the LaunchDaemon, running signed
  socket and `0.0.18` helper version stamp.
- SwiftUI enabled the MIPS TUN preference; **Control → Start Kumo** started a
  `rootService` core, installed the `utun4` split routes and passed HTTPS. The
  TUN toggle later removed the routes and preserved direct connectivity.
- SwiftUI enabled System Proxy on the auto-resolved Ethernet service, reported
  `owned` and passed HTTPS. With keep-core-running-on-quit off, **Quit Kumo**
  stopped Mihomo and disabled all managed system-proxy switches.
- `codesign --verify --deep --strict` passed for the installed bundle. The test
  build is ad-hoc signed and `spctl` rejected it as expected, so Developer ID,
  Gatekeeper acceptance and notarization remain distribution checks, not claims
  of either L2 run.

### L3 — User-gated migration

Changes to the production label, app-support root or daemon registration land
through the normal owner-approved install/upgrade flows, never through the dev
scripts.

## Verification Commands

Use:

```bash
swift build --product kumo
swift test
.build/debug/kumo --help
.build/debug/kumo capabilities --json
.build/debug/kumo prompt --list --json
.build/debug/kumo prompt topology route --json
.build/debug/kumo status --json
.build/debug/kumo skills install --agent codex --scope global --dry-run --json
```

Do not start a development server. This project is a Swift package, not a web app.
For user-facing release checks, prefer the bundled helper at
`Kumo.app/Contents/Helpers/kumo` and the `/usr/local/bin/kumo` symlink over
`swift run kumo`.

## Test Strategy

Prioritize tests that do not mutate real system state:

- Use temporary application support directories.
- Use dry-run for system proxy commands.
- Mock controller responses before testing live Mihomo APIs.
- Avoid tests that require a real network subscription.

## Areas That Need More Coverage

- Profile import and remote refresh errors.
- Missing core path errors.
- UI store behavior.
- Socket-tier failure and reconnect paths beyond the current tier-routing and
  handoff tests.
- Exact system proxy restore from snapshots.
- App update manifest and checksum flows.

## Quality Rules

- Keep `KumoCoreKit` independent from SwiftUI.
- Keep command execution isolated.
- Use explicit errors instead of generic failures.
- Keep advanced features behind advanced UI.
- Prefer small files grouped by domain responsibility.

## Manual QA Checklist

- `kumo status --json` returns valid JSON.
- `kumo capabilities --json` returns protocol `1.1`, all runnable commands, and
  `config apply` / `config rollback` in the rollback list; `kumo prompt profiles apply --json`
  returns the real diff/validate/apply loop and topology guidance uses
  `kumo topology --issues --json`.
- The main-window Agent Prompt menu changes with the selected destination and
  copies the same text as `kumo prompt <page> [intent]`; Settings exposes the
  settings prompt and Sub-Store shows no placeholder.
- `kumo --help`, `kumo -l`, `kumo help json`, and `kumo completion zsh` return
  npm-style discoverability output.
- `kumo status --color never` contains no ANSI escapes, and `kumo status --json`
  remains plain JSON even when `--color always` is supplied.
- `kumo status --silent` succeeds without successful text output.
- `kumo doctor --timing` writes timing diagnostics without polluting JSON output.
- `kumo logs cli --limit 5` and `kumo logs clean --dry-run --json` operate on
  CLI debug logs without touching runtime logs.
- Missing Mihomo core shows a clear error.
- Empty profile still generates a safe direct config.
- System proxy dry-run prints the expected commands.
- SwiftUI window opens with Overview selected.
- Settings opens with Cmd+,.
- Inspect search fields remain available when a query returns no matches.
- `kumo topology --json` returns a stable graph and `kumo topology --issues --json` returns only issues; the native Topology page keeps active and missing nodes visible when large columns are collapsed.
- Core runtime and System Proxy settings only commit after the user applies staged edits.
- TUN helper uninstall asks for confirmation before removing the service.
- `Settings → General → Background` installs and removes the Background Agent
  and reflects the tier state after each action.
- With TUN off, `Keep Mihomo running after quit` on, and the agent installed,
  quitting the GUI leaves the core serving; turning the preference off stops
  it on quit.
- Menu bar status item exposes start, stop, mode switching, refresh, profiles, proxy groups, and system proxy controls.
- App updates check the default GitHub Releases feed when no manifest override is set.
- App update DMG downloads fail closed on SHA-256 mismatch and report a clear error when the current app location is not writable.
- `kumo doctor --json` reports status, profile, and core candidate information.
- `kumo backup export <path> --json` creates a manifest-backed backup directory.
- `kumo substore status --json` reports enabled state, frontend/backend runtime
  state, resource version, and local URL without launching a dev server.

## Localization QA Checklist

- Settings → General shows the **Appearance** section with a Language dropdown.
- The dropdown contains **System Default** plus every language compiled into the app resource bundles (currently 18 languages including `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de`, `fr`, `es`, and others).
- Selecting a language triggers the **Restart Required** prompt.
- Clicking **Restart Now** terminates and relaunches the app.
- After restart, the app UI renders in the selected language (Settings labels, sidebar destinations, toolbar actions, mode names, About view, and menu bar status item).
- Selecting **System Default** removes `AppleLanguages` and the app follows macOS system language after restart.
- `preferences.json` contains `appLanguage` as a BCP-47 string (or `null`) after a change.
- String Catalog entries exist for all user-facing labels added in the same change set.
