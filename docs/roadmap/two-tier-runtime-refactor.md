# Two-Tier Runtime Refactor

Coordinator working document for the two-tier runtime refactor on branch
`feat/two-tier-runtime`. The shipped behavior now lives in the formal docs set
([ADR-005](../decisions/ADR-005-two-tier-runtime.md),
[Control Layer](../core/control-layer.md),
[Mihomo Runtime and Controller](../core/mihomo-runtime-controller.md),
[Service Mode Roadmap](service-mode-roadmap.md),
[CLI and Agent Control](../interfaces/cli-agent-control.md)); this file
records the stage log, verification layers, and what remains.

## Goal

Decouple GUI lifetime from Mihomo core lifetime (Sparkle-lightweight-mode
style): `Cmd+Q` may kill the GUI while the core keeps running, owned by a
user-level LaunchAgent (`kumod`, label `io.kumo.KumoAgent`). The existing
root LaunchDaemon (`io.kumo.KumoService`) remains for privileged operations
(TUN, root-owned core when TUN is on).

## Locked Decisions

- **D1 — TUN handoff restarts the core.** Toggling TUN moves core ownership
  between the user agent and the root daemon with a core restart (brief
  traffic gap). Accepted; matches Clash Verge Rev behavior.
- **D2 — Sub-Store stays as-is.** Not moved into kumod in this refactor.
  Backlog.
- **D3 — VM verification deferred.** `tart` 2.37.0 is installed on the host
  but no VM image is pulled. TUN/system-proxy global-effect verification
  becomes manual user acceptance; everything else is covered by L0/L1 (below).
- **D4 — CLI write-surface completion is in scope** (round-1 gap list:
  config get/set, rules, profile CRUD, dns/sniffer/tun settings, sysproxy
  set, provider updates, delay tests, streaming logs). Done in T3.
- **D5 — User-tier secret stays file-based** (`0600` in Application Support,
  same model as the root tier today). Keychain migration is backlog. The
  HMAC layer is defense-in-depth under same-uid anyway.

## Target Architecture

```
SwiftUI GUI ─┐
kumo CLI ────┼─► KumoController three-tier routing
App Intents ─┘        │
        ┌─────────────┼────────────────────┐
        ▼             ▼                    ▼
   direct mode    kumod (user)      KumoService (root)
   (fallback)     LaunchAgent       LaunchDaemon (unchanged)
                  owns core when    owns core only when TUN on;
                  TUN off; idle     privileged ops broker
                  auto-exit
```

Routing rule: TUN on → root daemon; TUN off + kumod alive → kumod; TUN off +
no kumod + root daemon alive → root daemon; otherwise → direct mode (local
`CoreSupervisor`). Same signed-socket protocol on both service tiers (shared
credentials file, distinct sockets).

## Stage Graph

- **S0 (serial)** — DONE (`655c824`): `KumoPaths` user-tier paths;
  `KumoService` binary `--mode root|user`; `KumoUserAgentManager`
  (SMAppService.agent + launchctl dev fallback); tests.
- **S1 (parallel worktrees, gated on S0)** — DONE:
  - T1 — DONE (`0a07ebe`): three-tier `BackendRouter` in KumoCoreKit;
    `prepareForAppTermination(policy:)`; TUN handoff with rollback;
    cross-tier reconnect. GUI wiring landed later in S2/T5.
  - T2 — DONE (`c8b827a`): kumod idle watchdog auto-exit, launchd
    socket activation (RunAtLoad/KeepAlive removed), agent.log
    lifecycle logging.
  - T3 — DONE (`f22f21d`): CLI completion — rules/profile/dns/sniffer/
    tun settings/sysproxy set/providers update/delay test/streaming/
    `kumo agent` commands.
  - T4 — DONE (`a16d574`): `KUMO_APP_SUPPORT_DIR`/`KUMO_AGENT_LABEL`
    env overrides; `Scripts/dev/agent-instance.sh` +
    `agent-smoke.sh` (hermetic E2E, PASS on merged tree).
- **S2 (serial; Xcode-dependent GUI and packaging work)** — DONE:
  - T5 — DONE (`f3268f7`): quit path wired to the termination policy via
    `UserPreferences.keepCoreRunningOnQuit`, Settings → General → Background
    toggle + Background Agent row.
  - T6 — DONE (`b6c1885`): bundled `Contents/MacOS/KumoService` +
    rendered `Contents/Library/LaunchAgents/io.kumo.KumoAgent.plist`
    (build-time render).
  - T7 — DONE (`1710ece`): `tierInstallState()` / `coreMigrationPlan()` /
    `migrateCoreToUserAgent()` and `kumo agent migrate`; pre-update core stop
    confirmed tier-aware.
  - T8 — DONE (`d56ac6b`): install-time validation of the bundled plist
    against the current machine, generated-plist + `launchctl bootstrap`
    fallback when the bundle moved.
  - Routing fix — DONE (`885e3e8`): surfaced by full Xcode verification —
    TUN-off core ops fall back agent → root daemon → local so an existing
    daemon-owned core stays visible and controllable.
- **S3** — DONE: docs sync (`docs/`, AGENTS.md requirement), ADR-005,
  CHANGELOG, de-marking stale "in progress" notes.
- **S4 — Release readiness for 0.0.17** — DONE (2026-10-06): version cut to
  0.0.17 (`MARKETING_VERSION`, `kumo --version`), CHANGELOG cut, and the
  Makefile post-build re-embed step made idempotent. Intel/amd64 releases
  are discontinued (owner decision); 0.0.17 and later ship arm64 only.

## Remaining Work

- **L2 VM acceptance** (D3): TUN + system-proxy global effects on a
  disposable tart VM. Manual user acceptance until a VM image is pulled.
- **Merge `feat/two-tier-runtime` to `main`.**

## Environment Notes (this machine)

- Xcode 27 installed: plain `swift build` / `swift test` work, KumoApp
  builds, XCTest runs. `KUMO_CLT_BUILD=1` remains the headless CLT-only
  fallback (drops Xcode-only targets).
- `tart` 2.37.0 is on `PATH`; no VM image pulled (see D3).
- Production state on this host: service mode installed + TUN enabled
  (observed via `kumo status --json`). With TUN on, the core stays
  root-owned by design (D1); lightweight quit applies when TUN is off.

## Verification Layers

- **L0** — `make swift-test`: temp app-support roots, ephemeral ports.
  Default verify for every task.
- **L1** — Dev-labeled on-host instance: real LaunchAgent registration,
  GUI-quit/core-survival, reconnect. sysproxy dry-run only (networksetup
  is global).
- **L2** — VM (tart): deferred per D3.
- **L3** — Host switchover: user runs migration explicitly at a chosen
  time, with rollback.

## Backlog (not this refactor)

- Sub-Store under kumod / PAC hosting move (D2).
- Keychain-backed service secrets (D5).
- tart VM harness (D3).
- Service-endpoint JSON schemas for automation consumers.
- Expanding root-daemon route parity for agent control when GUI is closed.
