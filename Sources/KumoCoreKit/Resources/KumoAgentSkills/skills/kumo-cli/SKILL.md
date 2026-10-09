---
name: kumo-cli
description: Drive Kumo, a macOS SwiftUI Mihomo client, from coding agents, scripts, and automation through the `kumo` CLI. Use when starting, stopping, inspecting, or changing Kumo runtime state, outbound mode, proxies, connections, providers, profiles, runtime config overrides, GUI preferences, rules, DNS, sniffer, TUN, system proxy, logs, traffic, the two-tier Kumo agent and Kumo Helper service, backups, Sub-Store, or bundled agent skill installation.
---

# Kumo CLI

`kumo` is the stable control surface over the same `KumoCoreKit` facade as the Kumo.app GUI and the runtime tiers. Every command accepts `--json`; agents should pass it by default.

## 1. Setup and output contract

- Use the installed `kumo`: onboarding symlinks `/usr/local/bin/kumo` to `Kumo.app/Contents/Helpers/kumo`; `kumo cli-link status|install|uninstall [--dry-run] [--json]` inspects or repairs that link. In a source tree, `swift run kumo ...` is a dev-only fallback.
- `cli-link install|uninstall` request a one-time macOS administrator authorization (osascript); uninstall removes the link only when Kumo manages it.
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

- `kumo proxies [--geo] [--json]` (alias `proxy`) — proxy groups and selected proxies. `--geo` additionally resolves a country code per node through the public ipwho.is GeoIP service (opt-in; see Safety rules).
- `kumo select <group> <proxy> [--json]`.
- `kumo test <proxy|group> [--url <url>] [--json]` — a group name tests every member; `--url` applies to single-proxy tests.
- `kumo connections [--close <id> | --close-all] [--json]` — list or close connections; `kumo connections close --ids <id1,id2,...> [--json]` closes a batch, reporting per-id failures without aborting the rest.
- `kumo providers [--json]` — proxy and rule provider counts.
- `kumo providers update --proxy <name> | --rule <name> | --geo | --all [--json]` — refresh one provider, upgrade GeoIP/GeoSite data, or update every provider (`--all` collects per-provider outcomes and never fails fast); at least one selector is required.

## 4. Profiles

- `kumo profile list [--json]` — ids, names, current selection (default subcommand).
- `kumo profile use <id>` — set the current profile.
- `kumo profile delete <id> [--dry-run] [--json]` — the `default` profile cannot be deleted.
- `kumo profile import <path|file-url>` — local YAML only; remote URLs fail with a pointer to `profile refresh`.
- `kumo profile content <id> [--json]` — profile YAML; unknown ids fail instead of printing the current profile.
- `kumo profile groups <id>` / `kumo profile nodes <id> [--json]` — preview proxy groups or nodes with upstream addresses by parsing the profile YAML on disk; no running core needed.
- `kumo profile refresh <url> [--json]` — fetch a remote subscription; a URL that already belongs to a stored profile refreshes that profile in place (preserving auto-update and the current selection), otherwise it imports a new current profile.
- `kumo profile refresh --id <id> [--use-proxy] [--json]` — refresh that profile in place and restart the core when it is current and running. `--use-proxy` (on either form) fetches through the local Mihomo proxy and needs a running core.
- `kumo profile update <id> [--name <name>] [--url <url>] [--auto-update|--no-auto-update] [--use-proxy|--no-use-proxy] [--dry-run] [--json]` — metadata only, no YAML re-download; omitted fields keep their stored values. Sub-Store-managed profiles reject `--url` with a pointer to `profile refresh --id`.
- `kumo profile edit <id> (--file <path> | --stdin) [--dry-run] [--json]` — replace the profile YAML (parse-validated; name and subscription settings are preserved).

## 5. Rules

- `kumo rules [--json]` — list rules with enabled state and index (default subcommand).
- `kumo rules enable <index>` / `kumo rules disable <index> [--json]` — indexes match `kumo rules` output.

## 6. Settings and preferences

- Preferences: `kumo prefs [get] [<key>] [--json]` and `kumo prefs set <key> <value> [--dry-run] [--json]` over `launchAtLogin`, `hideMenuBarIcon`, `quitOnLastWindowClose`, `keepCoreRunningOnQuit`, `updateChannel`, `appLanguage`, `hasCompletedOnboarding`. Values are typed (`true|false`, `stable|beta`, a BCP-47 tag such as `zh-Hans`, or `system`); a set preserves every key it does not expose, and notes flag deferred effects (next GUI launch or quit, GUI-only keys).
- Core runtime scalars (mixed port, allow LAN, log level, IPv6, process mode) are separate: see `kumo config get|set` under Backup and config.
- DNS: `kumo dns [--json]`, `kumo dns enable|disable`.
- Sniffer: `kumo sniffer [--json]`, `kumo sniffer enable|disable`.
- TUN: `kumo tun status [--json]`, `kumo tun settings [--json]`, `kumo tun enable|disable`.
- System proxy: `kumo sysproxy on|off [--dry-run]`; `kumo sysproxy set [--bypass <comma-list>] [--add-defaults] [--network-service <name>] [--host <host>] [--port <port>] [--mode manual|pac] [--dry-run]` — `--add-defaults` unions the current bypass list with the GUI default bypass list.
- Patch convention: `dns set`, `sniffer set`, `tun settings`, `config set`, and `sysproxy set` accept `--file <path>` or `--stdin` with a JSON object whose top-level keys match the corresponding settings type (`DnsSettings`, `SnifferSettings`, `TunSettings`, `CoreRuntimeSettings`, `SystemProxySettings`). Only provided keys change (shallow merge; arrays and nested objects are replaced wholesale); malformed JSON or schema mismatches fail cleanly. Applying DNS or sniffer settings while the core runs restarts it.
- `sysproxy set` explicit options and `--file`/`--stdin` are mutually exclusive; stored settings are re-applied when the system proxy is currently enabled.
- TUN enable/disable needs a privileged executor (Kumo Helper) and fails clearly when none is reachable; these two mutate immediately, without dry-run.

## 7. Override

- `kumo override list [--json]` (default) prints merge order; `kumo override content <id> [--json]` prints one body; `kumo override reorder --ids <id1,id2,...> [--restart]`.
- `kumo override add --name <name> (--file <path> | --stdin) [--format yaml|js] [--global] [--dry-run] [--restart]`; remote: `kumo override add --url <url> [--name <name>]`.
- `kumo override update <id> (--file <path> | --stdin) [--restart]`; `kumo override delete <id> [--dry-run] [--restart]` — ids are validated first, so unknown ids fail instead of silently doing nothing.
- Mutations match the GUI's next-start semantics: they apply when the core next starts; `--restart` restarts a running core to apply immediately, and `--dry-run` cannot be combined with `--restart`.
- Caveats reported as warnings: `--format js` bodies are stored but never merged, `--global` has no runtime effect yet, and remote `--url` adds are fetched directly without the proxy. Local `add --dry-run` validates the YAML.

## 8. Observation

- `kumo logs [runtime] [--limit <n>] [--level <level>] [--json]` — Mihomo runtime logs; `kumo logs --follow [--level <level>] [--json]` streams until Ctrl-C.
- `kumo logs cli [--limit <n>] [--level <level>] [--json]` — Kumo CLI debug logs; `kumo logs path` prints the logs directory; `kumo logs clean [--dry-run] [--json]` removes old CLI debug logs.
- `kumo traffic --watch [--json]` — `--watch` is required. With `--json`, `logs --follow` and `traffic --watch` emit one compact envelope per line (NDJSON); Ctrl-C exits with code 0.
- Connection listing and closing: see `kumo connections` under Proxy control. Offline profile previews (`kumo profile groups|nodes`) work without a running core.

## 9. Tiers and service

- Two-tier model: with TUN off, the user-level agent `kumod` owns the core so it keeps running after the GUI quits; with TUN on, the privileged Kumo Helper daemon owns it because TUN needs root; when neither socket tier is reachable, work runs in-process as the local supervisor.
- Routing is automatic and transparent: command names, flags, and JSON shapes do not change per tier, and a running root-owned core can be handed to the agent with `kumo agent migrate`.
- `kumo agent status|install|uninstall|migrate [--dry-run] [--json]` — manage `kumod`. `install` may refuse while a root-owned core is running; run `kumo agent migrate` first. `migrate` also refuses while TUN is enabled (disable TUN first) and requires the agent to be installed; it is a no-op when the agent already owns the core. `--dry-run` reports the installed tiers and the planned handoff.
- `kumo service status|install|uninstall [--json]` — manage the privileged Kumo Helper. Needed for TUN and used to delegate protected system proxy changes; install/uninstall request macOS administrator authorization and apply immediately.
- Each tier is optional for ordinary local use but enables a specific behavior: the agent for GUI-independent core ownership, Kumo Helper for TUN and privileged work.

## 10. Backup and config

- `kumo backup export <dir> [--json]` / `kumo backup import <dir> [--json]`.
- `kumo config path [--json]` (default) prints the application support directory; `kumo config list [--json]` prints profiles, work, logs, runtime config, and state paths (alias `c`).
- `kumo config get [key] [--json]` — stored `CoreRuntimeSettings`, whole or one of `mixedPort`, `allowLan`, `logLevel`, `ipv6`, `findProcessMode`, `geoData`.
- `kumo config set` — update `mixedPort`/`allowLan`/`logLevel`/`ipv6`/`findProcessMode` with explicit flags or a `--file`/`--stdin` JSON patch (mutually exclusive), with validation and `--dry-run`; DNS, sniffer, and TUN keys are rejected with a pointer to their dedicated commands.
- `kumo config secret [--set <value>] [--json]` — prints `set:true|false` and never the stored value; `--set` stores a new controller secret and notes that it takes effect the next time the core starts.

## 11. Sub-Store

- Lifecycle: `kumo substore status [--json]` (enabled state, backend, URL, resources), `kumo substore prepare [--json]`, `kumo substore start|stop|restart [--json]`.
- Content (read-only): `kumo substore subscriptions|collections|files|modules [--json]` list entries; `kumo substore content <name> [--kind subscription|collection|file] [--json]` prints one entry's detail; `kumo substore preview <name> [--kind ...]` returns the backend's parsed node arrays (never rendered Clash YAML); `kumo substore settings [--json]` and `kumo substore logs [--limit <n>] [--json]` read backend state and recent logs, falling back to the local log file when the backend is unreachable.
- `kumo substore import <name-or-path> [--name <profile-name>] [--use-proxy] [--json]` — a bare name resolves against subscriptions, then collections, to `/download/<name>`; explicit paths and URLs are used unchanged; imports as a Kumo profile. Write operations on Sub-Store content are intentionally out of scope.

## 12. Skills

- `kumo skills status [--json]` — per-agent install state.
- `kumo skills install [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--force] [--json]` (alias `add`).
- `kumo skills uninstall [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--json]`.
- Install is non-destructive: an existing untracked skill directory fails unless `--force` is passed. `codex` and `gemini` do not support project scope; `--agent all --scope project` targets only project-capable agents.

## 13. Safety rules

- Read first, write second: inspect with the relevant status/read command before mutating, then verify with the same command afterward.
- Preview with `--dry-run` where it exists: `sysproxy on|off|set`, `dns set`, `sniffer set`, `tun settings`, `profile delete|update|edit`, `override add|delete`, `config set`, `prefs set`, `agent install|uninstall|migrate`, `cli-link install|uninstall`, `skills install|uninstall`, `logs clean`. `tun enable|disable` and `service install|uninstall` apply immediately — confirm before running.
- `kumo proxies --geo` is the only command that sends node details off the machine: it resolves node hostnames through the public ipwho.is service. Run it only when that is acceptable; without the flag no hostname leaves the machine and the output is unchanged.
- Never hand-edit `state.json`, profile YAML, or generated runtime configuration when a `kumo` command exists.
- `kumo config secret` never prints the stored secret; `config secret --set` and `override --restart` report that they take effect on the next core start or restart.
- Pass `--force` only when replacing an existing untracked skill directory is intended.
- Logs and JSON output already redact profile URL tokens, controller secrets, and authorization headers; do not print secrets yourself.
- Prefer stable command names and JSON fields over parsing human-readable output.
