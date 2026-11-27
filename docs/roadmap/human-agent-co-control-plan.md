# Human-Agent Co-Control Plane Roadmap

Working design and execution plan for bringing the macOS SwiftUI GUI and the
`kumo` CLI to parity as a shared **Human-Agent Co-Control Plane** — so humans
and coding agents operate the same runtime, see each other's changes in real
time, share the same rollback and audit safety net, and get consistent behavior
whether the GUI is open or closed.

This document is structured so any coding agent or PI-coordinator session can
pick up a phase directly, dispatch scoped tasks, and verify completion.

## Goal

Kumo already shares `KumoCoreKit`, a two-tier runtime (`kumod` user LaunchAgent
+ `KumoService` root LaunchDaemon), transactional configuration with rollback,
and Agent Protocol 1.1 (`kumo capabilities --json`, `kumo prompt`,
`kumo topology`).

Four structural gaps remain between "two frontends sharing a library" and a
cohesive human-agent control plane:

1. **Cross-process state sync**: CLI/agent mutations do not notify an open GUI,
   leaving the UI stale or risking draft overwrites.
2. **Shared safety net & observability**: Rollback points (`ConfigurationRollbackStore`),
   CLI activity logs (`logs/cli.log`), and tier migration (`migrateCoreToUserAgent`)
   exist in core/CLI but are invisible in the GUI.
3. **Headless parity**: PAC hosting (`PACServer`) and App Intents (`KumoIntents`)
   still depend on the GUI process staying alive, and disabling system proxy
   does not restore `previousSystemProxySnapshot`.
4. **Hygiene & drift**: `KumoBackupManager.restoreStateFile` misses newer
   process-local fields, the bundled `kumo-cli` skill lacks `kumo dns source`,
   and release/ADR docs have minor drift.

## Guardrails & Non-Goals

Do not expand scope into the following unless explicitly re-prioritized:

- **No root-daemon full write-surface parity**: Keep the root LaunchDaemon
  scoped to TUN and privileged operations; control-plane mutations continue to
  flow through `KumoController` + `BackendRouter`.
- **No Sub-Store migration into `kumod`**: Leaving Sub-Store in the GUI process
  is acceptable until background subscription refresh without GUI becomes an
  explicit requirement.
- **No Keychain migration for service credentials**: Keep the `0600` file-based
  shared secret per ADR-005.
- **No standalone JSON Schema artifacts**: `kumo capabilities --json` (protocol
  1.1) is the canonical machine-readable contract.
- **No standalone mega-refactor PRs**: Do not pause feature work to split
  `KumoAppStore.swift`, `Models.swift`, or `KumoCoreKit.swift`; extract domain
  extensions opportunistically when touching those files.
- **Strict compliance with `AGENTS.md`**: Keep `KumoCoreKit` free of SwiftUI,
  use native macOS SwiftUI controls, avoid redundant UI copy, and update
  relevant `docs/` files in the same change set.

---

## Phased Execution Plan

Each phase is designed as an independent, reviewable PR with its own tests and
acceptance criteria.

### Phase 1 — Cross-Process Sync, Headless Intents & Hygiene

**Objective:** Make an open GUI immediately reflect CLI/agent mutations, make
App Intents work when the GUI is closed, and fix known state/doc drift.

#### 1.1 Cross-Process Change Broadcast (`KumoCoreKit` + `KumoApp`)

- **Target files:**
  - New: `Sources/KumoCoreKit/Support/ControlPlaneNotifier.swift`
  - Edit: `Sources/KumoCoreKit/KumoCoreKit.swift`,
    `Sources/KumoCoreKit/KumoController+ConfigurationTransactions.swift`,
    `Sources/KumoCoreKit/Service/KumoController+BackendRouting.swift`
  - Edit: `Sources/KumoApp/Stores/KumoAppStore.swift`
  - Tests: `Tests/KumoCoreTests/ControlPlaneNotifierTests.swift`,
    `Tests/KumoAppTests/`
- **Design:**
  - Define a lightweight `ControlPlaneChangeDomain: String, Codable, Sendable`
    (`status`, `profiles`, `overrides`, `preferences`, `rollbacks`, `all`) and
    a `ControlPlaneNotifier` backed by `DistributedNotificationCenter.default()`
    using notification name `io.kumo.controlPlaneDidChange`.
  - Include `senderPID` and `domains` in `userInfo` (only property-list safe
    primitives: `Int32` and `[String]`).
  - Emit notifications from `KumoController` write entry points after state /
    config persistence succeeds (start/stop/restart, mode, proxy selection,
    profile mutations, override mutations, DNS/Sniffer/TUN/sysproxy/prefs
    updates, config apply/rollback, agent migrate).
  - In `KumoAppStore`, observe `io.kumo.controlPlaneDidChange`, ignore events
    where `senderPID == ProcessInfo.processInfo.processIdentifier`, coalesce
    bursts with a ~200 ms debounce, and run targeted refreshes per domain
    instead of a full `refreshAll()` where possible.
  - When a Configure view holds an unsaved draft and an external update arrives
    for its domain, surface a non-intrusive notice rather than silently
    overwriting the user's in-progress edit.

#### 1.2 Headless App Intents Fallback (`KumoApp`)

- **Target files:**
  - Edit: `Sources/KumoApp/AppIntents/KumoIntents.swift`
  - Tests: `Tests/KumoAppTests/KumoAppContextTests.swift` (or new intent tests)
- **Design:**
  - Replace the hard failure in `IntentResolver.store()` when
    `KumoAppContext.shared.store == nil`.
  - When the live `KumoAppStore` is present, continue routing through the store
    so UI state updates immediately.
  - When the GUI is not running (`store == nil`), instantiate `KumoController()`
    directly and execute the requested operation (`start`, `stop`, `setMode`,
    `setSystemProxyEnabled`, `status`/refresh) via `BackendRouter`. The
    controller emits `ControlPlaneNotifier` events automatically.

#### 1.3 Backup Sanitization & Doc/Skill Drift Sync

- **Target files:**
  - Edit: `Sources/KumoCoreKit/Support/KumoBackupManager.swift`
  - Edit: `Sources/KumoCoreKit/Resources/KumoAgentSkills/skills/kumo-cli/SKILL.md`
  - Edit: `docs/agents.md`, `docs/README.md`
  - Tests: `Tests/KumoCoreTests/` (extend backup tests)
- **Changes:**
  - In `KumoBackupManager.restoreStateFile(from:)`, also clear host/process-local
    fields added in later PRs: `ownerTier`, `processStartTime`, `lastExit`,
    `previousSystemProxySnapshot`, `serviceModeStatus`, `tunStatus`.
  - Update bundled `kumo-cli/SKILL.md` to document `kumo dns source kumo|profile`
    (from PR #11 / ADR-006).
  - Remove retired `amd64` / `latest-amd64.yml` release steps from
    `docs/agents.md` (releases are arm64-only since `0.0.17`), and add
    `ADR-006` to the ADR lists in `docs/README.md` and `docs/agents.md`.

#### Phase 1 Acceptance Criteria

- With `Kumo.app` open, running `kumo mode`, `kumo profile use`, or
  `kumo dns source` updates the GUI within ~1 second without manual refresh.
- With `Kumo.app` closed (core running under `kumod`), invoking App Intents
  succeeds against `KumoController` instead of throwing `appNotReady`.
- Restoring a backup containing `ownerTier`, `processStartTime`, `lastExit`,
  `previousSystemProxySnapshot`, `serviceModeStatus`, or `tunStatus` clears all
  of those fields while preserving user settings.
- `make test` passes cleanly.

---

### Phase 2 — Shared Safety Net & Human-Agent Observability

**Objective:** Make CLI/agent configuration history, rollback, backup, and tier
migration visible and actionable in the native SwiftUI interface.

#### 2.1 GUI Rollback Surface (`KumoCoreKit` + `KumoApp`)

- **Target files:**
  - Edit: `Sources/KumoCoreKit/Configuration/ConfigurationRollbackStore.swift`
  - Edit: `Sources/KumoCoreKit/KumoController+ConfigurationTransactions.swift`
  - Edit: `Sources/KumoApp/Stores/KumoAppStore.swift`
  - Edit: `Sources/KumoApp/Views/ProfilesView.swift` and/or
    `Sources/KumoApp/Views/ConfigureViews/`
  - Tests: `Tests/KumoCoreTests/ConfigurationTransactionTests.swift`,
    `Tests/KumoAppTests/`
- **Design:**
  - Add a public summary model (`ConfigurationRollbackSummary`: `id`,
    `createdAt`, optional `source`/`summary`) and expose
    `KumoController.rollbackSummaries() throws -> [ConfigurationRollbackSummary]`
    plus `rollbackPointCount()`.
  - Keep `KumoAppStore.rollbackSummaries` synced on load and on `.rollbacks`
    change notifications.
  - Surface a concise native **Rollback** action (hidden or omitted when no
    rollback points exist, per `AGENTS.md` UI copy constraints) with a
    confirmation dialog showing the target timestamp. Rolling back calls
    `KumoController.rollbackConfiguration()` directly.

#### 2.2 Unified Activity View in Inspect → Logs (`KumoCoreKit` + `KumoApp`)

- **Target files:**
  - Edit or add reader in `Sources/KumoCoreKit/Support/` (read tail of
    `logs/cli.log` and `logs/runtime-events.jsonl` safely, mirroring the
    bounded tail-read pattern used for `core.log`).
  - Edit: `Sources/KumoApp/Stores/KumoAppStore.swift`
  - Edit: `Sources/KumoApp/Views/InspectViews.swift`
- **Design:**
  - Add a native segmented `Picker` in Logs (`Core` | `Activity`).
  - `Activity` merges recent bounded entries from `logs/cli.log` and
    `logs/runtime-events.jsonl`, sorted by timestamp descending, so humans can
    inspect recent CLI/agent commands, hot reloads, crashes, and rollbacks in
    one place.

#### 2.3 High-Value GUI Parity Actions (`KumoApp`)

- **Target files:**
  - Edit: `Sources/KumoApp/Views/SettingsView.swift`
  - Edit: `Sources/KumoApp/Stores/KumoAppStore.swift`
- **Design:**
  - **Backup export/import** in Settings → General using native macOS
    `NSOpenPanel` / `NSSavePanel` wired to `KumoController.exportBackup` /
    `importBackup` (with confirmation before import).
  - **One-click Agent Migration** in Settings → Background: when
    `coreMigrationPlan()` indicates a running root-owned core with TUN off and
    the user agent installed, show a native `Migrate to Agent` button calling
    `migrateCoreToUserAgent()`.

#### Phase 2 Acceptance Criteria

- After running `kumo config apply --file ...`, the GUI shows the new rollback
  point and the command appears in Inspect → Logs → Activity.
- Clicking Rollback in the GUI restores the prior config and hot-reloads the
  running core without restarting the process.
- Settings Backup export/import round-trips without error and refreshes GUI
  state.
- `make test` passes cleanly, including new `KumoAppTests` for rollback state
  and store refresh behavior.

---

### Phase 3 — Headless Network Parity (PAC in `kumod` & Snapshot Restore)

**Objective:** Eliminate the last two networking regressions when running
without the GUI or alongside pre-existing macOS proxy settings.

#### 3.1 Host `PACServer` in `kumod` (`KumoService` + `KumoCoreKit`)

- **Target files:**
  - Edit: `Sources/KumoService/main.swift` (and service route/idle-policy files)
  - Edit: `Sources/KumoCoreKit/Service/KumoServiceClient.swift`
  - Edit: `Sources/KumoCoreKit/Service/KumoController+BackendRouting.swift`
  - Edit: `Sources/KumoCoreKit/System/SystemProxyController.swift`
  - Tests: `Tests/KumoCoreTests/KumoControllerTierSocketTests.swift`,
    `Tests/KumoCoreTests/` (PAC lifecycle & idle-policy tests)
- **Design:**
  - Add signed Unix-socket endpoints on the user agent tier (`kumod`) for PAC
    hosting:
    - `POST /pac/start` (body: `{ "script": "..." }`) → returns `{ "port": UInt16, "url": "http://127.0.0.1:<port>/proxy.pac" }`
    - `POST /pac/stop`
    - `GET /pac/status`
  - Teach `kumod`'s idle watchdog (`ServiceIdlePolicy`) to stay alive while a
    PAC server is active (same rule as an active Mihomo core).
  - When `SystemProxyController` enables PAC mode and `kumod` is reachable,
    delegate PAC hosting to `kumod`; fall back to in-process `PACServer` only
    in direct mode (and document/warn when quitting in direct mode).
  - Result: `kumo sysproxy on` (in PAC mode) and GUI `Cmd+Q` with
    `keepCoreRunningOnQuit` both keep the local PAC endpoint serving traffic.

#### 3.2 Exact Previous System Proxy Snapshot Restoration (`KumoCoreKit`)

- **Target files:**
  - Edit: `Sources/KumoCoreKit/System/SystemProxyController.swift`
  - Edit: `Sources/KumoCoreKit/Models/Models.swift` (if structured parsing
    helpers are needed for `SystemProxySnapshot`)
  - Tests: `Tests/KumoCoreTests/SystemProxyOwnershipTests.swift`
- **Design:**
  - Parse the captured `SystemProxySnapshot` fields (`webProxy`,
    `secureWebProxy`, `socksProxy`, `bypassDomains`, `autoProxy`) into
    deterministic `networksetup` restore commands.
  - When disabling system proxy (and ownership check permits cleanup), if
    `previousSystemProxySnapshot` exists for the same `networkService`, apply
    the exact restore commands instead of blindly turning all proxies off.
  - Clear `previousSystemProxySnapshot` after successful restore; keep current
    full-off behavior when no snapshot exists or the snapshot had all proxies
    disabled.
  - Support `--dry-run` so tests and agents can inspect the exact restore
    command list without mutating host network settings.

#### Phase 3 Acceptance Criteria

- Running `kumo sysproxy set --mode pac && kumo sysproxy on` with `kumod`
  installed leaves `http://127.0.0.1:<port>/proxy.pac` reachable after the CLI
  process exits, and `kumo sysproxy off` stops the hosted PAC server cleanly.
- Quitting `Kumo.app` with `keepCoreRunningOnQuit = true` while PAC is active
  keeps PAC reachable.
- Dry-run and live tests verify that disabling system proxy restores a
  previously configured manual proxy, bypass list, or external PAC URL from
  `previousSystemProxySnapshot`.
- `make test` and L1 hermetic smoke (`Scripts/dev/agent-smoke.sh`) pass.

---

## Documentation Sync Checklist (Per Phase)

Update these docs in the same PR as the code changes:

- **Phase 1**: `docs/interfaces/cli-agent-control.md` (headless App Intents,
  change broadcast note), `docs/operations/persistence-logging.md` (backup
  sanitization), `docs/agents.md`, `docs/README.md`, `CHANGELOG.md`.
- **Phase 2**: `docs/interfaces/macos-swiftui-interface.md` (Rollback action,
  Activity logs segment, Settings Backup & Agent Migration), `CHANGELOG.md`.
- **Phase 3**: `docs/roadmap/service-mode-roadmap.md` &
  `docs/roadmap/sparkle-parity-roadmap.md` (mark PAC hosting in `kumod` and
  snapshot restore as implemented), `docs/core/control-layer.md`,
  `docs/operations/system-integration-permissions.md`, `CHANGELOG.md`.
