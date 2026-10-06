# CLI and Agent Control

## Purpose

The `kumo` executable provides a stable control surface for humans, shell scripts, and coding agents. It uses the same `KumoCoreKit` facade as the SwiftUI app.

## Installing `kumo` on PATH

`Kumo.app/Contents/Helpers/kumo` ships with the app bundle (`Helpers/` rather
than `MacOS/` so the CLI does not collide with the GUI's case-insensitive
`Contents/MacOS/Kumo`). The recommended install path is the first-run
onboarding sheet (also reachable via Settings > General > Command Line Tool),
which symlinks the bundled binary to `/usr/local/bin/kumo` after a one-time
macOS administrator authorization prompt. The same flow is wrapped by
`KumoController.cliLinkStatus()` / `installCLILink()` / `uninstallCLILink()`
for programmatic use, and exposed on the command line:

```bash
kumo cli-link [status] [--json]
kumo cli-link install [--dry-run] [--json]
kumo cli-link uninstall [--dry-run] [--json]
```

`status` reports the symlink state (`installed`, `notInstalled`,
`differentSymlink`, `occupiedByOther`, or `bundledCLIMissing`), the target
path, and the bundled binary path. `install` / `uninstall` need the one-time
macOS administrator authorization because `/usr/local/bin` is not
user-writable; `--dry-run` never prompts, it prints the current link state and
the intended action as a `CLILinkActionReport`. `uninstall` refuses to remove a
symlink or file that Kumo does not manage. Manual `ln -s` is supported but no
longer required for new installs.

`swift run kumo` is only a source-tree development smoke test. User-facing
installs must be validated through the bundled helper binary and, when
installed, the `/usr/local/bin/kumo` symlink that points at it.

## Command Design

Commands are intentionally close to user goals:

```bash
kumo status --json
kumo start --core /path/to/mihomo
kumo stop
kumo restart
kumo mode rule
kumo mode global
kumo mode direct
kumo proxies --json
kumo select "Proxy" "HK-01"
kumo rules --json
kumo rules enable 12
kumo test "Proxy" --url https://example.com --json
kumo profile list --json
kumo profile use default
kumo profile refresh "https://example.com/sub.yaml"
kumo profile refresh --id airport-1f2a3b4c --use-proxy
kumo profile update airport-1f2a3b4c --no-auto-update
kumo profile edit airport-1f2a3b4c --file ./airport.yaml
kumo profile import ./local.yaml
kumo override list --json
kumo override add --name dns-fix --file dns.yaml --dry-run --json
kumo dns --json
kumo dns set --file dns.json --dry-run --json
kumo sysproxy on --dry-run --json
kumo prefs get --json
kumo prefs set keepCoreRunningOnQuit true --json
kumo cli-link status --json
kumo service status --json
kumo service install
kumo agent status --json
kumo agent install --dry-run --json
kumo agent migrate --dry-run --json
kumo tun enable --json
kumo substore status --json
kumo skills status --json
kumo skills install --agent codex --dry-run --json
kumo completion zsh
kumo logs cli --limit 5
kumo logs --follow --level info
kumo traffic --watch --json
```

### Runtime Settings, Rules, and Providers

Read-only inspection and tuning commands that map directly onto the shared
`KumoController` facade:

```bash
kumo rules [--json]
kumo rules enable <index> | kumo rules disable <index>
kumo profile list [--json]
kumo profile use <id>
kumo profile delete <id> [--dry-run] [--json]
kumo profile import <path|file-url> [--json]      # local YAML; remote uses profile refresh
kumo profile content <id> [--json]
kumo profile refresh <url> [--use-proxy] [--json]
kumo profile refresh --id <id> [--use-proxy] [--json]
kumo profile update <id> [--name <name>] [--url <url>] [--auto-update|--no-auto-update] [--use-proxy|--no-use-proxy] [--dry-run] [--json]
kumo profile edit <id> --file <path>|--stdin [--dry-run] [--json]
kumo dns [--json] | kumo dns enable|disable [--json]
kumo sniffer [--json] | kumo sniffer enable|disable [--json]
kumo tun status|enable|disable [--json]
kumo tun settings [--json]
kumo sysproxy on|off [--dry-run] [--json]
kumo sysproxy set --add-defaults [--dry-run] [--json]
kumo providers [--json]                           # proxy/rule provider counts
kumo providers update --proxy <name> [--json]
kumo providers update --rule <name> [--json]
kumo providers update --geo [--json]
kumo providers update --all [--json]              # every proxy and rule provider
kumo test <proxy|group> [--url <url>] [--json]
```

`kumo test` treats a name that matches a proxy group as a group test (every
member is probed); other names are tested as a single proxy. `--url` applies
to single-proxy tests.

`kumo providers update --all` updates every provider returned by the running
core's proxy and rule provider listings. Each provider's outcome is collected
into one `ProvidersUpdateAllReport`; a failing provider never stops the run,
so the report names every failure instead of only the first one. `--all`
cannot be combined with `--proxy`/`--rule`; `--geo` may be added to upgrade
the GeoIP/GeoSite data files after the loop. The command still exits `0` when
only some providers failed — the report's `failed` count is the signal.

#### Profiles

`kumo profile refresh <url>` refreshes in place when a profile with the same
subscription URL is already stored: the profile keeps its id and name, the
current selection does not change, and the stored auto-update preference is
preserved. Only a URL that no profile uses is imported, and a new import
becomes the current profile with auto-update enabled. Repeating the same URL
therefore never duplicates a profile or force-switches the current one.

`kumo profile refresh --id <id>` re-downloads that profile in place (Sub-Store
profiles refresh through Sub-Store). When the refreshed profile is the current
one and the core is running, the core is restarted so the new YAML takes
effect, mirroring the GUI. `--use-proxy` fetches through the local Mihomo
proxy and fails with a clear error when no core is running.

`kumo profile update <id>` merges the provided flags over the stored metadata:
omitted fields (`--name`, `--url`, `--auto-update`, `--use-proxy`) keep their
stored value, so an update can never demote a subscription or disable
auto-update by omission. `--auto-update` / `--no-auto-update` and
`--use-proxy` / `--no-use-proxy` set the stored preference explicitly.
`--dry-run` prints the merged metadata without writing. The profile YAML is
not re-downloaded; use `profile refresh` for that.

`kumo profile edit <id>` replaces the profile YAML from `--file <path>` or
`--stdin`. The replacement must parse as a YAML mapping; `--dry-run` validates
it without writing. Name and subscription settings are preserved.

`kumo profile content <id>` fails on an unknown id instead of falling back to
the current profile, so scripts never print the wrong profile. The id must
appear in `kumo profile list`.

#### Settings patches

`dns set`, `sniffer set`, `tun settings` (with input), and `sysproxy set`
accept `--file <path>` or `--stdin` with a JSON object whose top-level keys
match the corresponding settings type (`DnsSettings`, `SnifferSettings`,
`TunSettings`, `SystemProxySettings`). Only the provided keys are changed;
arrays and nested objects are replaced wholesale. The command fails cleanly
when the JSON is malformed or a value does not match the schema.

`--dry-run` prints the merged settings without writing state and without
restarting the core. Applying DNS or sniffer settings while the core is
running restarts the core, exactly like the SwiftUI settings panes.

`kumo sysproxy set` also supports explicit options (`--bypass <comma-list>`,
`--network-service`, `--host`, `--port`, `--mode manual|pac`,
`--add-defaults`); explicit options and `--file`/`--stdin` are mutually
exclusive. Stored settings are re-applied when the system proxy is currently
enabled. `--add-defaults` unions the resulting bypass list with
`SystemProxySettings.defaultBypassList` — the same list the GUI's "Add
Defaults" button uses, shared through `KumoCoreKit` — dropping duplicates and
sorting the result, so it is idempotent and works together with `--bypass` or
a patch.

#### GUI preferences (`kumo prefs`)

```bash
kumo prefs [get] [<key>] [--json]
kumo prefs set <key> <value> [--dry-run] [--json]
```

`kumo prefs` owns the stored `UserPreferences` (`preferences.json`) that the
SwiftUI app reads on launch and in Settings. Exposed keys:
`launchAtLogin`, `hideMenuBarIcon`, `quitOnLastWindowClose`,
`keepCoreRunningOnQuit`, `updateChannel`, `appLanguage`, and
`hasCompletedOnboarding`.

`prefs get` prints the whole set or one key; unknown keys fail with the list
of valid ones. In JSON output `appLanguage` is `null` when the app follows the
system language.

`prefs set` reads the stored preferences, changes only the given key, and
writes the whole set back, so unrelated keys — including
`updateManifestURL`, which the CLI does not expose — keep their stored values.
Values are type-checked: booleans are strict `true`/`false` (`yes`/`1` are
rejected), `updateChannel` is `stable|beta`, and `appLanguage` is a BCP-47 tag
such as `en` or `zh-Hans`, or `system` to store `nil` (follow the system
language). `--dry-run` prints the merged preferences without writing.

Two keys only take effect inside the GUI:

- `launchAtLogin` is honoured on the next GUI launch, which calls
  `SMAppService.mainApp.register()`/`unregister()`; the CLI never registers
  the login item itself.
- `keepCoreRunningOnQuit` takes effect on the next GUI quit
  (`prepareForAppTermination(policy:)`).

`hideMenuBarIcon` is a GUI-only preference, and `hasCompletedOnboarding` is
settable for recovery scenarios (the GUI re-opens onboarding when it is
`false`). Mutating `prefs set` commands print these notes in text output.

### Overrides

```bash
kumo override [list] [--json]
kumo override content <id> [--json]
kumo override add --name <name> (--file <path> | --stdin) [--format yaml|js] [--global] [--dry-run] [--restart] [--json]
kumo override add --url <url> [--name <name>] [--format yaml|js] [--global] [--restart] [--json]
kumo override update <id> (--file <path> | --stdin) [--restart] [--json]
kumo override delete <id> [--dry-run] [--restart] [--json]
kumo override reorder --ids <id1,id2,...> [--restart] [--json]
```

Overrides are edits merged into the runtime config; they are never applied to
a live core in place, matching the GUI, which performs no core restart after
an override edit.

- **Next start, not now.** Active YAML overrides merge into the runtime
  config when the core starts (`RuntimeConfigBuilder` at launch). Every
  mutating command states `takes effect on next core start` in text output.
  Pass `--restart` to restart a running core and apply the change
  immediately; with no running core `--restart` is a no-op and the command
  reports `core not running`.
- **Only YAML is applied.** `--format js` stores the body but it is never
  merged into the runtime config; `add` warns about this.
- **`--global` has no runtime effect yet.** The flag is stored on the item but
  global overrides are not applied anywhere; `add` warns about this.
- **Remote fetches are unproxied.** `add --url` downloads the body directly
  (no proxy support) before storing it.
- **Ordering.** `list` prints the merge order by ascending index.
  `reorder --ids` moves the listed ids to the front in the given order;
  unlisted ids keep their relative order after them.
- **Ids are pre-validated.** `content`, `update`, `delete`, and `reorder`
  fail with `Unknown override id: <id>` instead of relying on the core API's
  silent no-op for unknown delete ids. `reorder` also rejects duplicate ids.
- **Dry run.** Local `add --dry-run` validates that the YAML parses (for
  `--format yaml`) without writing; `delete --dry-run` names the item that
  would be removed. `--dry-run` cannot be combined with `--restart`.

#### Runtime settings (`kumo config get|set|secret`)

```bash
kumo config get [<key>] [--json]
kumo config set --mixed-port <port> [--allow-lan <bool>] [--log-level <level>] [--ipv6 <bool>] [--find-process-mode <mode>] [--dry-run] [--json]
kumo config set --file <path> [--dry-run] [--json]
kumo config set --stdin [--dry-run] [--json]
kumo config secret [--set <secret>] [--json]
```

`config get` prints the stored `CoreRuntimeSettings` object; with a key
(`mixedPort`, `allowLan`, `logLevel`, `ipv6`, `findProcessMode`, `geoData`) it
prints only that value. Unknown keys fail listing the valid ones.

`config set` owns the scalar runtime fields (`mixedPort`, `allowLan`,
`logLevel`, `ipv6`, `findProcessMode`) and accepts either explicit flags or a
`--file`/`--stdin` JSON object patch; the two input styles are mutually
exclusive. `mixedPort` must be `1...65535`, `logLevel` one of
`silent|error|warning|info|debug`, and `findProcessMode` one of
`always|strict|off`. A patch rejects unknown top-level keys with the list of
valid ones. The `dns`, `sniffer`, and `tun` keys are rejected with a pointer
to `kumo dns set`, `kumo sniffer set`, and `kumo tun settings`; geo data is
read-only here (`config get geoData`). `--dry-run` prints the merged settings
without writing state or patching the running core.

`config secret` reports `set=true|false` without ever printing the stored
value; `--set <secret>` stores a new secret. The secret is read when the core
starts, so a new secret takes effect on the next core start, not on a running
core.

Patches for `DnsSettings`, `SnifferSettings`, and `TunSettings` also reject
unknown top-level keys and list the valid ones.

## CLI Interaction Conventions

Kumo follows the parts of npm's CLI interaction model that make command-line
tools discoverable and scriptable:

- `kumo --help` / `kumo -h` shows common tasks, all command names, and next-step
  help prompts.
- `kumo -l` / `kumo --long` expands command descriptions, usage, options, and
  aliases.
- `kumo <command> -h` and `kumo help <term>` provide command-level help.
- `kumo --version` prints only the version string.
- `kumo completion <zsh|bash|fish>` writes a shell completion script to stdout.
- Conservative aliases are allowed for low-risk read paths: `status` → `st`,
  `proxies` → `proxy`, and `config` → `c`.
- Commands that can write system or user state should support `--dry-run` where
  a meaningful preview is possible.

## Output Modes

The default output is readable text. `--json` returns a stable wrapper:

```json
{
  "ok": true,
  "data": {},
  "error": null
}
```

Errors use the same wrapper with `ok: false`.

`--json` output is always plain JSON on stdout. It must not include ANSI escape
codes, progress text, warnings, or diagnostic logs. Human-readable diagnostics
go to stderr in text mode.

## Terminal Rendering

Text mode uses light ANSI styling only when stdout/stderr are interactive TTYs.
Rendering is disabled when output is piped or redirected, when `--json` is used,
when `NO_COLOR` is set, when `CLICOLOR=0`, or when `--color never` is passed.
`--color always|auto|never` defaults to `auto`.

Visible status labels are ASCII so color is never the only signal:

- `[ok]` for healthy success.
- `[warn]` for warnings or partial readiness.
- `[error]` for failures.
- `[dry-run]` for previews.

## CLI Logging

Kumo uses npm-style log controls:

- `--loglevel <silent|error|warn|notice|http|info|verbose|silly>` controls
  terminal diagnostics. The default is `notice`.
- `--silent` is equivalent to `--loglevel silent`; `--verbose` is equivalent to
  `--loglevel verbose`; `-d` is equivalent to `--loglevel info`.
- Normal command results are written to stdout. Logs, warnings, progress, timing
  output, and diagnostics are written to stderr.
- `--logs-dir <path>` overrides the CLI debug log directory. By default CLI logs
  live under `logs/cli/`.
- `--logs-max <count>` limits retained CLI debug logs. `--logs-max=0` disables
  debug log files.
- `--timing` writes a process-specific timing JSON file and may print a timing
  summary to stderr in text mode.
- Logs redact profile URL tokens, controller secrets, authorization headers,
  basic auth passwords, and similar credentials before writing terminal or file
  output.

`kumo logs` has two log surfaces:

- `kumo logs [runtime] [--limit <count>] [--level <level>] [--json]` shows
  Mihomo/runtime logs.
- `kumo logs --follow [--level <level>] [--json]` streams new Mihomo log
  entries until Ctrl-C.
- `kumo logs cli [--limit <count>] [--level <level>] [--json]` shows Kumo CLI
  debug log summaries.
- `kumo logs path` prints the logs directory.
- `kumo logs clean [--dry-run] [--json]` cleans old CLI debug and timing logs.

`kumo traffic --watch [--json]` streams live Mihomo traffic counters; traffic
is only available as a live stream, so `--watch` is required. In `--json`
mode, `--follow` and `--watch` write one compact
`{ok,data,error}` envelope per line (NDJSON). Ctrl-C exits both streams
cleanly with code 0.

## Agent-Friendly Behavior

Agent workflows need predictable behavior:

- `--json` should be supported for every command.
- Dry-run should be available for commands that change system settings.
- Agent skill installation should use `kumo skills ... --dry-run` before writing
  into user or project agent skill directories.
- Exit code `0` means success.
- Exit code `1` means the command failed and `error` explains why.
- Command names should remain stable even if implementation moves to a service later.

## Agent Skills

`kumo skills` installs the bundled `kumo-cli` Agent Skill into supported coding
agent skill directories. The CLI and macOS Integrations UI both use the same
`KumoCoreKit` target mapping and install state.

Supported agents:

- `cursor` → `~/.cursor/skills` globally, `.cursor/skills` for project scope.
- `claude` → `~/.claude/skills` globally, `.claude/skills` for project scope.
- `codex` → `$CODEX_HOME/skills` or `~/.codex/skills` globally.
- `gemini` → `~/.gemini/skills` globally.
- `agents` → `~/.agents/skills` globally, `.agents/skills` for project scope.
- `all` → every target supported by the selected scope.

Commands:

```bash
kumo skills status [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--json]
kumo skills install [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--force] [--json]
kumo skills uninstall [--agent <cursor|claude|codex|gemini|agents|all>] [--scope <global|project>] [--dry-run] [--json]
```

Install is non-destructive by default. If a destination skill directory already
exists and was not recorded as installed by Kumo, the command fails unless the
caller explicitly passes `--force`.

`codex` and `gemini` do not support project scope. `--agent all --scope project`
targets only agents with project-scope support.

## User-Level Agent (kumod)

The two-tier runtime adds an unprivileged user agent tier, `io.kumo.KumoAgent`
("kumod"), that owns the Mihomo core so the GUI can quit while the core keeps
running. It is managed through `KumoUserAgentManager` and shares the
credentials file with the privileged helper; only the socket
(`kumo-agent.sock`), log path, and launchd domain (`gui/<uid>`) differ. launchd
keeps the socket endpoint and starts the agent on demand; the agent exits
again after an idle timeout.

```bash
kumo agent status [--json]
kumo agent install [--dry-run] [--json]
kumo agent uninstall [--dry-run] [--json]
kumo agent migrate [--dry-run] [--json]
```

`kumo agent status` uses the same text and JSON shape as
`kumo service status` (`ServiceModeStatus`). `--dry-run` prints the planned
plist/socket paths and current state without touching launchd, the
LaunchAgents plist, or the socket.

`kumo agent migrate` hands a running, root-owned core to the user agent. It
refuses while TUN is enabled (the core must stay root-owned) and until the
agent is installed, with the refusal reason in the error envelope. Ownership
comes from the running core's record (`CoreStatus.ownerTier`), so a root-owned
core is still handed over after the agent install makes routing prefer the
agent; only legacy states without a record fall back to the router's owner.
With no running core, or when the agent already owns it, it is a no-op
success, so re-running it is safe. `--dry-run` prints the installed tiers
(`none|rootOnly|userOnly|dual`), the current core owner
(`rootService|userAgent|localSupervisor|unavailable`), the TUN state, and any
guard refusals without stopping or starting anything.

## App Intents (GUI surface)

The macOS app additionally exposes the following App Intents (via
`KumoIntents.swift`) so Shortcuts, Siri, and Spotlight can drive Kumo
without spawning a CLI process:

- `Start Kumo`
- `Stop Kumo`
- `Refresh Kumo`
- `Set Kumo Mode` (parameter: `KumoModeChoice` ↔ `OutboundMode`)
- `Toggle Kumo System Proxy` (parameter: `enable: Bool`)

App Intents call back into the live `KumoAppStore`, so their effects are
identical to triggering the same flow from the GUI. They require the
`Kumo.app` bundle (not `swift run`).

## Shared Control Layer

The CLI must not bypass `KumoCoreKit`. Commands run against whichever tier
`BackendRouter` selects — the user agent whenever TUN is off and the agent is
reachable, the root daemon for TUN and privileged operations — while keeping
command names and JSON schemas compatible whether the GUI is open or closed:

- `kumo start|stop|restart` delegates Mihomo lifecycle to the owning tier
  (user agent or root daemon).
- `kumo start` waits for the controller endpoint to answer `GET /version` after
  the core is spawned, matching the app and the daemon. When the controller
  never becomes ready the command fails with the underlying reason and the
  `logs/core.log` path instead of reporting a plain success.
- `kumo sysproxy on|off` delegates protected system proxy changes to the helper
  unless `--dry-run` is used.
- `kumo tun enable|disable` delegates TUN state changes to the helper and fails
  clearly when no helper or privileged process can manage `utun`.
- `kumo service install|uninstall|status` reports LaunchDaemon/socket state and
  uses macOS administrator authorization for install and uninstall.
- `kumo agent install|uninstall|status` manages the user-level LaunchAgent
  tier through `KumoUserAgentManager`; it uses a generated plist in
  `~/Library/LaunchAgents` for source-tree runs and `SMAppService.agent` in
  bundled builds.
- `kumo agent migrate` routes through `KumoController.migrateCoreToUserAgent()`
  (guards + `transferCoreOwnership`), so the CLI and the GUI share the same
  tier handoff behavior.
- `kumo substore status|prepare|start|stop|restart` manages bundled Sub-Store
  resources and the same local lifecycle used by the SwiftUI app.

App Intents still call `KumoAppStore` directly. Routing them through service
endpoints so they keep working when the GUI is closed remains follow-up work
(part of the root-daemon route-parity gap tracked in the two-tier backlog).

## Future Work

- Add JSON schemas for automation consumers.
