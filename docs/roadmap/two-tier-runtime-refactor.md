# Two-Tier Runtime Refactor (Working Plan)

Coordinator working document for the two-tier runtime refactor on branch
`feat/two-tier-runtime`. Will be folded into the formal docs set at S3.

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
- **D3 — VM verification deferred.** `tart` is not installed on the host.
  TUN/system-proxy global-effect verification becomes manual user
  acceptance; everything else is covered by L0/L1 (below).
- **D4 — CLI write-surface completion is in scope** (round-1 gap list:
  config get/set, rules, profile CRUD, dns/sniffer/tun settings, sysproxy
  set, provider updates, delay tests, streaming logs).
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

Routing rule: TUN on → root daemon; TUN off + kumod alive → kumod;
otherwise → direct mode. Same signed-socket protocol on both service tiers
(shared credentials file, distinct sockets).

## Stage Graph

- **S0 (serial)** — DONE (`655c824`): `KumoPaths` user-tier paths;
  `KumoService` binary `--mode root|user`; `KumoUserAgentManager`
  (SMAppService.agent + launchctl dev fallback); tests.
- **S1 (parallel worktrees, gated on S0)** — DONE:
  - T1 — DONE (`0a07ebe`): three-tier `BackendRouter` in KumoCoreKit;
    `prepareForAppTermination(policy:)`; TUN handoff with rollback;
    cross-tier reconnect. GUI wiring (calling the policy on quit) is
    NOT done — needs Xcode (see S2).
  - T2 — DONE (`c8b827a`): kumod idle watchdog auto-exit, launchd
    socket activation (RunAtLoad/KeepAlive removed), agent.log
    lifecycle logging.
  - T3 — DONE (`f22f21d`): CLI completion — rules/profile/dns/sniffer/
    tun settings/sysproxy set/providers update/delay test/streaming/
    `kumo agent` commands.
  - T4 — DONE (`a16d574`): `KUMO_APP_SUPPORT_DIR`/`KUMO_AGENT_LABEL`
    env overrides; `Scripts/dev/agent-instance.sh` +
    `agent-smoke.sh` (hermetic E2E, PASS on merged tree).
- **S2 (serial; mostly BLOCKED on Xcode install)** — GUI wiring
  (KumoAppDelegate calls `prepareForAppTermination(policy:)` driven by
  a new preference + Settings toggle + agent install UI + handoff
  copy); app-bundle packaging of the agent plist/helper; root→user
  migration handoff + dual-tier detection; update-installer interplay.
- **S3** — Docs sync (`docs/`, AGENTS.md requirement), ADR-005, CHANGELOG.

## Environment Notes (this machine)

- No Xcode (CLT only): KumoApp cannot compile, XCTest cannot run.
  Builds/tests use `KUMO_CLT_BUILD=1 swift build`; XCTest suites are
  written for CI and typechecked locally.
- tart 2.40.1 installed at `~/.local/share/tart` (VM image not pulled).
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
