# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.17] - 2026-10-06

### Added
- `Keep Mihomo running after quit` (Settings → General → Background): the GUI
  can quit while Mihomo keeps serving under the user agent or root daemon.
  Backed by `UserPreferences.keepCoreRunningOnQuit` and
  `KumoController.prepareForAppTermination(policy:)`.
- `Background Agent` row in Settings → General → Background to install,
  remove, and inspect the user-level LaunchAgent (`kumod`,
  `io.kumo.KumoAgent`).
- User-level agent tier: `kumod` runs as the logged-in user behind launchd
  socket activation (`kumo-agent.sock`), owns the core when TUN is off, and
  idle-exits after 5 minutes with no core running.
- TUN ownership handoff: enabling or disabling TUN transfers core ownership
  between the user agent and the root daemon through `transferCoreOwnership`,
  which stops the core on the source tier and starts it on the target tier; if
  the target start fails, rollback restores the core on the source tier. TUN
  always runs privileged, and TUN-off cores can outlive the GUI.
- `kumo agent status|install|uninstall|migrate` plus `tierInstallState()`,
  `coreMigrationPlan()`, and `migrateCoreToUserAgent()` for dual-tier
  detection and root-to-agent migration.
- CLI write surface: `rules list|enable|disable`; `providers update
  --proxy|--rule|--geo`; `test`; profile `list|use|delete|import|content`;
  `dns` / `sniffer` show|enable|disable|set; `tun settings`; `sysproxy set`;
  JSON settings patches via `--file` / `--stdin`.
- Streaming CLI output: `kumo logs --follow` and `kumo traffic --watch`
  (NDJSON in `--json` mode, Ctrl-C exits cleanly).
- Dev infrastructure: `KUMO_APP_SUPPORT_DIR` / `KUMO_AGENT_LABEL` overrides
  and hermetic `Scripts/dev/` agent instance and smoke scripts.

### Changed
- Quit now routes through `prepareForAppTermination(policy:)`: `.stopRuntime`
  preserves the previous stop behavior; `.keepCoreAlive` (the new preference)
  leaves the core and Kumo-managed system proxy running.
- Core lifecycle and privileged operations route through the tier that owns
  the core: TUN on → root daemon; TUN off → user agent → root daemon → local
  process. An existing root-daemon-owned core stays visible and controllable
  until it is migrated.
- `KumoService service run --mode root|user` selects the tier; root mode is
  unchanged. Both tiers use the same signed socket protocol and credentials
  file.
- `Kumo.app` ships the user-tier payload (`Contents/MacOS/KumoService` and a
  rendered `Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist`); the
  installer validates the plist for the current machine before
  `SMAppService.agent` registration and falls back to a generated
  `~/Library/LaunchAgents` plist plus `launchctl bootstrap`.
- CLT-only machines can build with `KUMO_CLT_BUILD=1` to skip Xcode-only
  targets.

## [0.0.16] - 2026-10-02

### Fixed
- The privileged helper now repairs the app-support tree to the authorized user
  at startup (upgrading installs already in the broken state) and after every
  request that can write state, so `state.json`, `logs/runtime-events.jsonl`
  and `work/*` no longer stay `root:staff 0644` on fresh service-mode installs.
  Runtime-event and readiness bookkeeping is best-effort on the caller side, so
  a denied bookkeeping write can no longer turn a ready core into a failed
  `kumo start`; direct-mode state and pid persistence still fail loudly.
  (Issue #3)
- Core liveness treats `EPERM` from `kill(pid, 0)` as "alive". A core running as
  root via the privileged helper is no longer misjudged as dead by an
  unprivileged app or CLI, which cleared the recorded PID and allowed a second
  core to be launched. Stale-PID cleanup now only triggers on genuine death
  (`ESRCH`).
- `stop()` no longer reports `Mihomo core stopped.` for a process the caller
  cannot signal. Permission failures are detected immediately, the PID record
  is kept, and the failed stop names the unreachable PID.
- `kumo start` waits for the controller to answer before reporting success and
  fails with the reason plus the `logs/core.log` path when the core never comes
  up.
- App update checks and release manifests point at `tom-cat-mao/mihomo-swift`
  instead of the unmaintained upstream repository.

### Added
- `CoreSupervisor.start()` probes the configured controller port before
  spawning and throws `controllerPortInUse` when another process already owns
  it, so a lost PID record can no longer turn into a double launch.
- Privileged-helper lookup accepts the bundled `Contents/MacOS/KumoService`
  next to the CLI shipped at `Contents/Helpers/kumo`, so installing the helper
  works from the app-bundled CLI.
- Multi-agent PI-coordinator workflow documentation (`AGENTS.md`,
  `docs/agents.md`, `.pi/external-agent/templates/`).

### Changed
- `logs/core.log` rotates to `logs/core-<yyyyMMdd-HHmmss>.log` before each
  launch, so concurrent cores no longer interleave writes into one file and
  `core.log` always describes the current session.
- The GUI no longer performs controller work on the main thread. `KumoApp` goes
  through `CoreRuntimeRunner`, a serial `public actor` in `KumoCoreKit` that
  owns one `KumoController`, so the 1 Hz status refresh, profile polls, proxy
  reloads and Inspect refreshes stop blocking the UI. The synchronous
  `KumoController` facade is unchanged for the CLI and the privileged helper.
- `recentLogs(limit:)` reads only the last 256 KB of `logs/core.log` instead of
  loading the whole file, which grows for the lifetime of a session (112 MB on
  the development machine) and was re-read on every refresh. Log entry ids are
  now content-derived (`"<message-hash>-<occurrence>"`) instead of positional,
  so appending no longer renumbers existing entries; consumers of
  `kumo logs runtime --json` must treat `id` as an opaque per-process token,
  and its values changed.
- Helper IPC is bounded again: the connect is non-blocking with a 1 s poll
  bound, `SO_SNDTIMEO` caps the request write at 10 s, and the polling
  `GET /service/status` and `GET /status` paths also get a 10 s
  `SO_RCVTIMEO`. Mutating requests keep their previous receive behavior. A
  missing, restarting or wedged helper now surfaces as
  `KumoError.serviceUnavailable` instead of parking the caller.
- Profile YAML parses are memoized on the profile file's
  `(fileURL, contentModificationDate, fileSize)` identity, so the three parses
  a single `loadProxyGroups()` performs, plus the 60 s profile poll and the
  stopped-core sidebar preview, reuse one result until the file changes.
- UI hot paths stop repeating identical work: the status item and dock badge
  observers skip writes when nothing changed, the byte-count and
  relative-date formatters are cached instead of allocated per call, the
  Connections, Logs and proxies list bodies compute their filtered collections
  once per pass instead of two or three times, the DNS, TUN, Sniffer and
  System Proxy views normalize their draft once per pass instead of once per
  enablement read, and the country-code write-back mutates proxy elements in
  place instead of copying the whole group list.

## [0.0.15] - 2026-05-23

### Internationalization
- Replaced all hardcoded UI strings with `String(localized:)` across 25 Swift files for full i18n support.

### Infrastructure
- Bumped marketing version to 0.0.15.

## [0.0.14] and earlier

See git history for earlier changes.
