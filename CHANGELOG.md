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

## [0.0.15] - 2026-05-23

### Internationalization
- Replaced all hardcoded UI strings with `String(localized:)` across 25 Swift files for full i18n support.

### Infrastructure
- Bumped marketing version to 0.0.15.

## [0.0.14] and earlier

See git history for earlier changes.
