---
name: kumo-cli
description: Drive Kumo, a macOS SwiftUI Mihomo client, from coding agents, scripts, and automation through the `kumo` CLI. Use when starting, stopping, inspecting, or changing Kumo runtime state, outbound mode, proxies, connections, providers, profiles, rules, DNS, sniffer, TUN, system proxy, logs, traffic, the two-tier Kumo agent and Kumo Helper service, backups, Sub-Store, or bundled agent skill installation.
---

# Kumo CLI

`kumo` is the stable control surface over the same `KumoCoreKit` facade as the Kumo.app GUI and the runtime tiers. Every command accepts `--json`; agents should pass it by default.

## 1. Setup and output contract

- Use the installed `kumo`: onboarding symlinks `/usr/local/bin/kumo` to `Kumo.app/Contents/Helpers/kumo`. In a source tree, `swift run kumo ...` is a dev-only fallback.
- Sanity check `kumo status --json`; broad snapshot `kumo doctor --json`; `kumo --version` prints the version.
- Discover the surface with `kumo --help`, `kumo -l`, `kumo <command> -h`, `kumo help <term>`; `kumo completion zsh|bash|fish` prints completion scripts. Run `kumo help <command>` for exact flags — they are not duplicated here.
- Output contract: stdout JSON envelope `{"ok": true|false, "data": ..., "error": ...}`; exit `0` success, `1` failure (read `error` when `ok` is false). Diagnostics go to stderr; `--json` stdout is always plain JSON.
- `--silent --json` suppresses text output for scripts; `--loglevel` controls CLI diagnostics.
- Prefer read commands before writes, and re-run the narrow read command after a write to verify.

## 2. Lifecycle

- `kumo status [--json]` — state, outbound mode, core pid.
- `kumo start [--core <path>]`, `kumo stop`, `kumo restart [--core <path>]` — `start` waits for the core controller and fails with the `logs/core.log` path when it never becomes ready.
- `kumo mode rule|global|direct [--json]` — set outbound mode.
- `kumo doctor [--json]` — runtime state, current profile, core candidates.
- `kumo runtime-events [--limit <n>] [--json]` — recent Kumo runtime events.
- `kumo core install [--json]` — install the managed Mihomo core.

## 3. Proxy control

- `kumo proxies [--json]` (alias `proxy`) — proxy groups and selected proxies.
- `kumo select <group> <proxy> [--json]`.
- `kumo test <proxy|group> [--url <url>] [--json]` — a group name tests every member; `--url` applies to single-proxy tests.
- `kumo connections [--close <id> | --close-all] [--json]` — list or close active connections.
- `kumo providers [--json]` — proxy and rule provider counts.
- `kumo providers update --proxy <name> | --rule <name> | --geo [--json]` — refresh one provider or upgrade GeoIP/GeoSite data; at least one selector is required.

## 4. Profiles

- `kumo profile list [--json]` — ids, names, current selection (default subcommand).
- `kumo profile use <id>` — set the current profile.
- `kumo profile delete <id> [--dry-run] [--json]` — the `default` profile cannot be deleted.
- `kumo profile import <path|file-url>` — local YAML only; remote URLs fail with a pointer to `profile refresh`.
- `kumo profile content <id> [--json]` — profile YAML.
- `kumo profile refresh <url> [--json]` — fetch a remote subscription; re-running with the current profile's URL updates and re-applies that profile.

## 5. Rules

- `kumo rules [--json]` — list rules with enabled state and index (default subcommand).
- `kumo rules enable <index>` / `kumo rules disable <index> [--json]` — indexes match `kumo rules` output.

## 6. Settings (DNS, sniffer, TUN, system proxy)

- DNS: `kumo dns [--json]`, `kumo dns enable|disable`.
- Sniffer: `kumo sniffer [--json]`, `kumo sniffer enable|disable`.
- TUN: `kumo tun status [--json]`, `kumo tun settings [--json]`, `kumo tun enable|disable`.
- System proxy: `kumo sysproxy on|off [--dry-run]`; `kumo sysproxy set [--bypass <comma-list>] [--network-service <name>] [--host <host>] [--port <port>] [--mode manual|pac] [--dry-run]`.
- Patch convention: `dns set`, `sniffer set`, `tun settings`, and `sysproxy set` accept `--file <path>` or `--stdin` with a JSON object whose top-level keys match the corresponding settings type (`DnsSettings`, `SnifferSettings`, `TunSettings`, `SystemProxySettings`). Only provided keys change (shallow merge; arrays and nested objects are replaced wholesale); malformed JSON or schema mismatches fail cleanly. Applying DNS or sniffer settings while the core runs restarts it.
- `sysproxy set` explicit options and `--file`/`--stdin` are mutually exclusive; stored settings are re-applied when the system proxy is currently enabled.
- TUN enable/disable needs a privileged executor (Kumo Helper) and fails clearly when none is reachable; these two mutate immediately, without dry-run.

## 7. Observation

- `kumo logs [runtime] [--limit <n>] [--level <level>] [--json]` — Mihomo runtime logs; `kumo logs --follow [--level <level>] [--json]` streams until Ctrl-C.
- `kumo logs cli [--limit <n>] [--level <level>] [--json]` — Kumo CLI debug logs; `kumo logs path` prints the logs directory; `kumo logs clean [--dry-run] [--json]` removes old CLI debug logs.
- `kumo traffic --watch [--json]` — `--watch` is required. With `--json`, `logs --follow` and `traffic --watch` emit one compact envelope per line (NDJSON); Ctrl-C exits with code 0.
- Connection listing and closing: see `kumo connections` under Proxy control.

## 8. Tiers and service

- Two-tier model: with TUN off, the user-level agent `kumod` owns the core so it keeps running after the GUI quits; with TUN on, the privileged Kumo Helper daemon owns it because TUN needs root; when neither socket tier is reachable, work runs in-process as the local supervisor.
- Routing is automatic and transparent: command names, flags, and JSON shapes do not change per tier, and a running root-owned core can be handed to the agent with `kumo agent migrate`.
- `kumo agent status|install|uninstall|migrate [--dry-run] [--json]` — manage `kumod`. `install` may refuse while a root-owned core is running; run `kumo agent migrate` first. `migrate` also refuses while TUN is enabled (disable TUN first) and requires the agent to be installed; it is a no-op when the agent already owns the core. `--dry-run` reports the installed tiers and the planned handoff.
- `kumo service status|install|uninstall [--json]` — manage the privileged Kumo Helper. Needed for TUN and used to delegate protected system proxy changes; install/uninstall request macOS administrator authorization and apply immediately.
- Each tier is optional for ordinary local use but enables a specific behavior: the agent for GUI-independent core ownership, Kumo Helper for TUN and privileged work.

## 9. Backup and config

- `kumo backup export <dir> [--json]` / `kumo backup import <dir> [--json]`.
- `kumo config path [--json]` (default) prints the application support directory; `kumo config list [--json]` prints profiles, work, logs, runtime config, and state paths (alias `c`).

## 10. Sub-Store

- `kumo substore status [--json]` — enabled state, backend, URL, resources.
- `kumo substore prepare [--json]` — prepare bundled resources.
- `kumo substore start|stop|restart [--json]`.

## 11. Skills

- `kumo skills status [--json]` — per-agent install state.
- `kumo skills install [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--force] [--json]` (alias `add`).
- `kumo skills uninstall [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--json]`.
- Install is non-destructive: an existing untracked skill directory fails unless `--force` is passed. `codex` and `gemini` do not support project scope; `--agent all --scope project` targets only project-capable agents.

## 12. Safety rules

- Read first, write second: inspect with the relevant status/read command before mutating, then verify with the same command afterward.
- Preview with `--dry-run` where it exists: `sysproxy on|off|set`, `dns set`, `sniffer set`, `tun settings`, `profile delete`, `agent install|uninstall|migrate`, `skills install|uninstall`, `logs clean`. `tun enable|disable` and `service install|uninstall` apply immediately — confirm before running.
- Never hand-edit `state.json`, profile YAML, or generated runtime configuration when a `kumo` command exists.
- Pass `--force` only when replacing an existing untracked skill directory is intended.
- Logs and JSON output already redact profile URL tokens, controller secrets, and authorization headers; do not print secrets yourself.
- Prefer stable command names and JSON fields over parsing human-readable output.
