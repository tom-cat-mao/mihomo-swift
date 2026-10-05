# Testing and Quality

## Current Tests

The first test suite covers:

- Runtime config generation.
- Core state persistence.
- System proxy command construction in dry-run mode.
- Mihomo controller response mapping with mocked URL loading.
- Backup export/import round trips.
- Service request signing.
- CLI argument parsing, JSON envelope stability, color/log rendering rules, and
  npm-style help behavior.
- Dev-instance environment overrides (`KUMO_APP_SUPPORT_DIR`,
  `KUMO_AGENT_LABEL`) and user-agent label plumbing into the generated plist.
- Two-tier runtime: routing decisions across TUN/agent/root/local, TUN
  ownership handoff and rollback, the app termination policy, root-to-agent
  migration guards, tier socket behavior, and the user-agent manager's launchd
  plist and idle policy.
- App-level behavior (`Tests/KumoAppTests/`): quit-path sidecar termination,
  termination policy mapping, startup store attach for App Intents, and the
  update-install flow including tier version-stamp repair prompts.

These tests target `KumoCoreKit` because that layer carries the most important shared behavior.

## Testing Layers

Runtime verification is layered by isolation, cheapest first. Higher layers are
manual/opt-in and never replace L0.

| Layer | What it proves | Where it runs | Entry point |
|-------|----------------|---------------|-------------|
| L0 | Unit behavior: core kit, signing, launchd plists, idle policy | CI / local `swift test` | `swift test` |
| L1 | The agent tier installs, activates on demand, idles out and relaunches on this host, hermetically | Owner's Mac, disjoint dev label + `/tmp` app-support | `Scripts/dev/agent-smoke.sh` |
| L2 | Root daemon, system proxy, TUN and app bundle on a disposable VM | tart VM (deferred) | not wired up yet |
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

### L2 — Disposable VM (deferred)

A tart-based macOS VM is the target for exercising the root daemon, system
proxy, TUN and the app bundle without touching the owner's machine. Not wired
up yet.

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
