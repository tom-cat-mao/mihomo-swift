# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
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
