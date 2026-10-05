# Persistence and Logging

## Application Support Directory

Kumo stores local state under:

```text
~/Library/Application Support/Kumo/
```

`KumoPaths` centralizes all paths so GUI, CLI, tests, and future service code use the same layout.

## Directory Layout

```text
Kumo/
  profiles/
    default.yaml
    profiles-metadata.json
    current.txt
  overrides/
    overrides.json
    files/
  work/
    config.yaml
  logs/
    core.log
    core-<yyyyMMdd-HHmmss>.log
    substore.log
    agent.log
  cores/
    mihomo
  substore/
    status.json
    backend/
    frontend/
  kumo-agent.sock
  state.json
  preferences.json
```

## File Ownership

State, log and work files are owned by whichever side touches them first, so
ownership depends on install order. The privileged helper runs as root and
therefore hands the app-support tree back to the authorized user: at daemon
startup and again after every request that can write app-support state.
`AppSupportOwnershipRepair` chowns the root plus every non-symlinked descendant
to that user's uid and primary gid. Symlinked entries are skipped and never
followed, and `/Library/PrivilegedHelperTools/io.kumo.KumoService` and the
launchd plist stay root-owned. The repair is a no-op when the caller is not
root.

Bookkeeping tolerates the repair being incomplete. `logs/runtime-events.jsonl`
appends never throw — a denied append logs a warning and drops the row — and the
`controllerReady` bookkeeping a caller writes after a helper-routed start
degrades the same way, because in service mode the helper's `state.json` is the
authoritative record. In direct (no-helper) mode, `state.json` and
`work/core.pid` stay load-bearing and still throw when they cannot be written,
so a core is never left running without a record that `status()` or `stop()`
can act on.

## User-Level Agent (In Progress)

The user-level agent tier ("kumod", `io.kumo.KumoAgent`) is being introduced
alongside the root helper. It owns the Mihomo core so the GUI can quit while
the core keeps running, and binds the same signed Unix socket protocol at:

```text
kumo-agent.sock
```

Its launchd stdout/stderr are appended to:

```text
logs/agent.log
```

The agent runs as the logged-in user, so its socket and credentials are
created 0600 owned by that user, and `AppSupportOwnershipRepair` — a root
concern — does not apply. It reuses `service-credentials.json`, so credentials
are shared across both tiers. The root daemon's socket and log paths are
unchanged. See
[Service Mode Roadmap](../roadmap/service-mode-roadmap.md#user-level-agent-tier-in-progress)
for the staged plan.

The agent is on demand rather than permanently resident. Its generated
LaunchAgent declares a launchd `Sockets` entry for `kumo-agent.sock`
(`RunAtLoad=false`, `KeepAlive=false`), so launchd owns the socket and starts
the agent on the first connection; the agent adopts the descriptor with
`launch_activate_socket` and falls back to binding the socket itself for
manual/dev runs. It then exits on its own after `--idle-timeout` seconds
(default 300) without a served client request and with no Mihomo core
running; it never exits while a core is running. Because launchd owns the
socket, the endpoint survives the agent's exit and triggers the next start.

`logs/agent.log` is both the launchd stdout/stderr target and the agent's
lifecycle log: service start, socket bound/adopted, observed core start/stop,
and idle-exit with reason are appended there. When stdout already points at
the same file (the launchd case) the direct file append is skipped so lines
are not duplicated; interactive runs write to both.

## Backup Format

Kumo can export a directory backup containing:

- `manifest.json`
- `profiles/`
- `overrides/`
- `substore/`
- `state.json`

The first backup format is directory-based rather than zip-based so it remains
transparent, testable, and easy for agents to inspect. A future UI can wrap the
same manifest in a compressed archive or sync it to WebDAV without changing the
CoreKit import/export contract.

## State File

`state.json` stores `CoreStatus`:

- core run state
- process identifier
- outbound mode
- controller endpoint
- mixed proxy port
- system proxy state (including PAC `mode` and `pacScript`)
- controlled runtime settings, including TUN stack, routing, DNS, route
  exclusions, MTU, and ICMP forwarding preferences
- last status message

This allows the CLI and GUI to share state without requiring a service in v1.
Runtime setting models must decode missing fields with defaults so app updates
can add new TUN controls without invalidating an existing `state.json`.

## User Preferences

`preferences.json` stores `UserPreferences` (UI lifecycle preferences that do
not affect Mihomo runtime):

- `launchAtLogin` — synced with `SMAppService.mainApp` by `KumoAppDelegate`.
- `hideMenuBarIcon` — persisted for the menu bar visibility preference; Kumo now uses
  an AppKit `NSStatusItem`, so runtime visibility can be wired through the status item
  controller when the Settings toggle is re-exposed.
- `quitOnLastWindowClose` — read by
  `applicationShouldTerminateAfterLastWindowClosed`.
- `keepCoreRunningOnQuit` — Settings → General → Background toggle. When true,
  `KumoAppStore.prepareForTermination()` passes `.keepCoreAlive` to
  `prepareForAppTermination(policy:)`, leaving the core with its owning tier
  (user agent or root daemon) after the GUI quits. Decoded with
  `decodeIfPresent` so older `preferences.json` files without it default to
  `false` (today's stop-on-quit behavior).
- `updateChannel` (`stable` / `beta`) and `updateManifestURL` — feed
  `AppUpdateManager.checkForUpdate(...)`. A blank `updateManifestURL` uses
  Kumo's default GitHub Releases feed; a value overrides it for local testing
  or private distribution.
- `appLanguage` — an optional BCP-47 language tag (e.g. `en`, `zh-Hans`).
  `nil` means follow the system language. On launch `LocalizationManager` reads
  this value and writes it to the standard `AppleLanguages` UserDefaults key so
  macOS resolves the correct `.lproj` at the next launch. The field is decoded
  with `decodeIfPresent` so older `preferences.json` files without it default to
  `nil`.

Decoding falls back to defaults so a missing or corrupted file never blocks
launch.

## App Updates

App update downloads are cached under:

```text
updates/downloads/
```

The detached DMG installer writes its log to:

```text
logs/app-update-installer.log
```

The cache is disposable. Release metadata and artifact rules are documented in
[Release Management](release-management.md).

## Sub-Store

`substore/status.json` (`SubStoreStatus`) stores enable flag, custom backend
URL, host/LAN mode, proxy mode, cron settings, resource version, copied bundle
paths, and configured ports.

Bundled Sub-Store resources are copied from `KumoCoreKit` into:

```text
substore/resources/
  manifest.json
  node/bin/node
  backend/sub-store.bundle.js
```

Sub-Store runtime data is kept under `substore/data/`, matching
`SUB_STORE_DATA_BASE_PATH`. Temporary staging work belongs under
`substore/temp/`. There is no bundled web frontend: Kumo's SwiftUI Sub-Store
surface talks to the local backend over HTTP directly.

`SubStoreSupervisor` launches the bundled Node sidecar with
`sub-store.bundle.js` and Sparkle-compatible environment variables. Stopping
Sub-Store terminates the backend process and closes the log handle.

## Runtime Configuration

The generated Mihomo runtime configuration is written to:

```text
work/config.yaml
```

Mihomo is launched with the work directory so it reads the generated config.

## Logs

Core stdout and stderr are appended to:

```text
logs/core.log
```

`CoreSupervisor.start()` rotates that file before every launch: when
`logs/core.log` exists and is non-empty, it is renamed to
`logs/core-<yyyyMMdd-HHmmss>.log` (local time) and a fresh `core.log` is
opened for the new process. A core that is still running keeps writing to its
own rotated file, so lines from concurrent cores no longer interleave, and
`core.log` always describes the current session. Rotation is best-effort: if
the rename fails, the launch continues and the log keeps growing.

Readers never load the whole file. `recentLogs(limit:)` seeks to end-of-file,
seeks back at most 256 KB and reads that window, then keeps the last `limit`
complete lines. A window boundary that falls mid-line is dropped, so callers
never receive a truncated first line. This matters because the file grows for
the lifetime of a session and is read on every Inspect refresh, TUN status
probe and connection-close handler.

Log entry ids are content-derived (`"<message-hash>-<occurrence>"`) rather
than positional, so appending to the log does not renumber existing entries.
They are opaque identity tokens: the hash is seeded per process, so ids are
stable within a session but must not be persisted or compared across runs.

Sub-Store backend stdout and stderr are appended to:

```text
logs/substore.log
```

Each Sub-Store launch writes a header line (`[ISO timestamp] starting <executable> <args>`) so log readers can split sessions easily.

The main UI intentionally does not expose full logs on the Overview screen. Full log inspection belongs in the `Logs` destination under `Inspect`. The `Sub-Store` settings page surfaces a "View Logs" button that opens `logs/substore.log` in the user's text editor.

Live Mihomo logs should be treated as an event stream with a bounded in-memory cache. The local `core.log` file remains a fallback and diagnostic artifact.

The CLI has a separate debug-log channel under:

```text
logs/cli/
```

Each `kumo` invocation may create a `*-kumo-debug-0.log` file with command-level
diagnostics. `--logs-max <count>` controls retention, and `--logs-max=0`
disables CLI debug log files for sensitive environments. `--logs-dir <path>`
can redirect these files for temporary diagnostics.

`kumo --timing` writes a process-specific `*-kumo-timing.json` file in the same
directory. Timing files are for performance diagnostics and should not be mixed
with runtime event streams.

CLI terminal output follows npm-style log levels:

```text
silent < error < warn < notice < http < info < verbose < silly
```

Normal command results go to stdout. Logs, warnings, progress, timing summaries,
and debug-log paths go to stderr. `--json` keeps stdout as plain JSON only.

Before writing terminal or file logs, CLI diagnostics redact controller secrets,
authorization headers, basic auth passwords, subscription tokens, and token-like
query parameters. Redaction is a safety net, not a reason to paste logs into
public places without review.

## Overrides

Overrides are planned under:

```text
overrides/
  overrides.json
  files/
    <id>.yaml
    <id>.js
    <id>.log
```

YAML overrides are applied before Kumo-controlled runtime settings. JavaScript overrides require a reviewed sandbox before they are enabled.

## Future Work

- Add retention/cleanup for rotated `core-*.log` files.
- Add separate app and service logs.
- Add structured JSONL event logs for agents.
- Add privacy review for logs before sharing diagnostics.
- Add log rotation and Sub-Store log retention controls.
