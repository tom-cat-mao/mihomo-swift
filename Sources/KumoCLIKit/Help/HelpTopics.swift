/// Curated `kumo help <term>` topics.
///
/// `CommandIndex` decides which commands exist; this registry only supplies
/// the short human-readable text. A completeness test keeps the two in sync,
/// and `HelpText.topic` synthesizes a topic from ArgumentParser metadata for
/// command paths that have no curated entry here.
struct HelpTopic {
    var summary: String
    var usage: [String]
    var options: [String] = []
    var example: String
    var details: [String] = []
}

enum HelpTopics {
    static let byPath: [String: HelpTopic] = [
        "status": HelpTopic(
            summary: "Show current Kumo runtime state.",
            usage: ["kumo status [--json]"],
            example: "kumo status --json"
        ),
        "start": HelpTopic(
            summary: "Start Kumo with the managed Mihomo core.",
            usage: ["kumo start [--core <path>] [--json]"],
            options: ["--core <path>   Use a specific Mihomo core executable instead of the managed core."],
            example: "kumo start --json"
        ),
        "stop": HelpTopic(
            summary: "Stop the running Mihomo core.",
            usage: ["kumo stop [--json]"],
            example: "kumo stop"
        ),
        "restart": HelpTopic(
            summary: "Restart Kumo.",
            usage: ["kumo restart [--core <path>] [--json]"],
            options: ["--core <path>   Use a specific Mihomo core executable instead of the managed core."],
            example: "kumo restart --json"
        ),
        "mode": HelpTopic(
            summary: "Set the outbound mode.",
            usage: ["kumo mode <rule|global|direct> [--json]"],
            example: "kumo mode global --json"
        ),
        "proxies": HelpTopic(
            summary: "List proxy groups and their selected proxies.",
            usage: ["kumo proxies [--json]"],
            example: "kumo proxies --json"
        ),
        "select": HelpTopic(
            summary: "Select a proxy for a group.",
            usage: ["kumo select <group> <proxy> [--json]"],
            example: #"kumo select "Proxy" "HK-01" --json"#
        ),
        "rules": HelpTopic(
            summary: "List Mihomo rules or toggle one by index.",
            usage: [
                "kumo rules [--json]",
                "kumo rules enable <index> [--json]",
                "kumo rules disable <index> [--json]"
            ],
            example: "kumo rules enable 3 --json",
            details: ["Indexes match the index shown by `kumo rules`."]
        ),
        "profile": HelpTopic(
            summary: "Manage profiles.",
            usage: [
                "kumo profile list [--json]",
                "kumo profile use <id> [--json]",
                "kumo profile delete <id> [--dry-run] [--json]",
                "kumo profile import <path|file-url> [--json]",
                "kumo profile content <id> [--json]",
                "kumo profile refresh <url> [--use-proxy] [--json]",
                "kumo profile refresh --id <id> [--use-proxy] [--json]",
                "kumo profile update <id> [--name <name>] [--url <url>] [--auto-update|--no-auto-update] [--use-proxy|--no-use-proxy] [--dry-run] [--json]",
                "kumo profile edit <id> --file <path>|--stdin [--dry-run] [--json]"
            ],
            example: "kumo profile list --json",
            details: [
                "`profile import` imports a local YAML file. Remote subscriptions use `profile refresh`.",
                "`profile refresh <url>` refreshes the matching profile in place when its subscription URL is already stored — same id, no duplicate, current selection kept. A new URL is imported as a new current profile.",
                "`profile update` merges only the provided flags over the stored metadata; omitted fields keep their value. `profile edit` validates the replacement YAML before writing."
            ]
        ),
        "profile refresh": HelpTopic(
            summary: "Refresh a subscription in place or import a remote profile URL.",
            usage: [
                "kumo profile refresh <url> [--use-proxy] [--json]",
                "kumo profile refresh --id <id> [--use-proxy] [--json]"
            ],
            options: [
                "--id <id>       Refresh this profile in place.",
                "--use-proxy     Fetch through the local Mihomo proxy; requires a running core."
            ],
            example: "kumo profile refresh --id airport-1f2a3b4c --json",
            details: [
                "A URL already stored on a profile refreshes that profile in place without changing the current selection; the first time a URL is seen it is imported as a new current profile.",
                "`--id` refreshes the profile in place and restarts the core when the refreshed profile is the current one and the core is running."
            ]
        ),
        "profile update": HelpTopic(
            summary: "Update a profile's name, subscription URL, or update preferences.",
            usage: [
                "kumo profile update <id> [--name <name>] [--url <url>] [--auto-update|--no-auto-update] [--use-proxy|--no-use-proxy] [--dry-run] [--json]"
            ],
            options: [
                "--name <name>           Rename the profile.",
                "--url <url>             Set the subscription URL.",
                "--auto-update           Enable automatic updates (--no-auto-update disables).",
                "--use-proxy             Refresh through the local Mihomo proxy (--no-use-proxy disables).",
                "--dry-run               Print the merged metadata without writing."
            ],
            example: "kumo profile update airport --name \"Airport A\" --no-auto-update --json",
            details: ["Omitted fields keep their stored value; the profile YAML is not re-downloaded (use `kumo profile refresh`)."]
        ),
        "profile edit": HelpTopic(
            summary: "Replace a profile's YAML from a file or stdin.",
            usage: [
                "kumo profile edit <id> --file <path> [--dry-run] [--json]",
                "kumo profile edit <id> --stdin [--dry-run] [--json]"
            ],
            options: [
                "--file <path>   Read the replacement YAML from a file.",
                "--stdin         Read the replacement YAML from stdin.",
                "--dry-run       Validate the YAML without writing."
            ],
            example: "kumo profile edit airport --file ./airport.yaml --dry-run --json",
            details: ["The replacement must parse as a YAML mapping. Name and subscription settings are preserved."]
        ),
        "dns": HelpTopic(
            summary: "Show or update DNS runtime settings.",
            usage: [
                "kumo dns [--json]",
                "kumo dns enable [--json]",
                "kumo dns disable [--json]",
                "kumo dns set --file <path> [--dry-run] [--json]",
                "kumo dns set --stdin [--dry-run] [--json]"
            ],
            example: "kumo dns set --stdin --dry-run --json",
            details: [
                "`dns set` reads a JSON object whose keys match DnsSettings. Only the provided keys are changed; the core restarts when settings are applied while running. Use --dry-run to preview the merged settings."
            ]
        ),
        "sniffer": HelpTopic(
            summary: "Show or update sniffer runtime settings.",
            usage: [
                "kumo sniffer [--json]",
                "kumo sniffer enable [--json]",
                "kumo sniffer disable [--json]",
                "kumo sniffer set --file <path> [--dry-run] [--json]",
                "kumo sniffer set --stdin [--dry-run] [--json]"
            ],
            example: "kumo sniffer set --file sniffer.json --json",
            details: [
                "`sniffer set` reads a JSON object whose keys match SnifferSettings. Only the provided keys are changed; the core restarts when settings are applied while running."
            ]
        ),
        "tun": HelpTopic(
            summary: "Manage TUN state and settings.",
            usage: [
                "kumo tun status [--json]",
                "kumo tun enable [--json]",
                "kumo tun disable [--json]",
                "kumo tun settings [--json]",
                "kumo tun settings --file <path> [--dry-run] [--json]",
                "kumo tun settings --stdin [--dry-run] [--json]"
            ],
            example: "kumo tun settings --json",
            details: [
                "`tun settings` without input prints the current settings; with --file/--stdin it merges a JSON object whose keys match TunSettings."
            ]
        ),
        "tun settings": HelpTopic(
            summary: "Show TUN settings or update them from a JSON patch.",
            usage: [
                "kumo tun settings [--json]",
                "kumo tun settings --file <path> [--dry-run] [--json]",
                "kumo tun settings --stdin [--dry-run] [--json]"
            ],
            options: [
                "--file <path>   Read a JSON settings patch from a file.",
                "--stdin         Read a JSON settings patch from stdin.",
                "--dry-run       Preview the update without writing."
            ],
            example: "kumo tun settings --stdin --dry-run --json",
            details: ["With no input this prints the current settings. A patch is a JSON object whose keys match TunSettings."]
        ),
        "sysproxy": HelpTopic(
            summary: "Control the macOS system proxy.",
            usage: [
                "kumo sysproxy on [--dry-run] [--json]",
                "kumo sysproxy off [--dry-run] [--json]",
                "kumo sysproxy set --bypass <comma-list> [--network-service <name>] [--host <host>] [--port <port>] [--mode manual|pac] [--dry-run] [--json]",
                "kumo sysproxy set --file <path> [--dry-run] [--json]",
                "kumo sysproxy set --stdin [--dry-run] [--json]"
            ],
            example: "kumo sysproxy on --dry-run --json",
            details: ["`sysproxy set` updates stored settings and re-applies them when the system proxy is currently enabled."]
        ),
        "service": HelpTopic(
            summary: "Manage Kumo service mode.",
            usage: [
                "kumo service status [--json]",
                "kumo service install",
                "kumo service uninstall"
            ],
            example: "kumo service status --json",
            details: ["Service mode installs the privileged helper used for TUN and system proxy control. Use `kumo agent` for the user-level agent tier."]
        ),
        "agent": HelpTopic(
            summary: "Manage the user-level Kumo agent (kumod).",
            usage: [
                "kumo agent status [--json]",
                "kumo agent install [--dry-run] [--json]",
                "kumo agent uninstall [--dry-run] [--json]",
                "kumo agent migrate [--dry-run] [--json]"
            ],
            example: "kumo agent status --json",
            details: [
                "The user agent (io.kumo.KumoAgent) owns the Mihomo core so it keeps running when the Kumo app quits. It starts on demand and exits after an idle timeout. `agent status` uses the same shape as `service status`.",
                "`agent migrate` hands a running root-owned core to the user agent so the privileged daemon no longer owns it. It refuses while TUN is enabled (the core must stay root-owned) and until the agent is installed. --dry-run reports the installed tiers, the current core owner, and the planned handoff without stopping or starting anything."
            ]
        ),
        "agent migrate": HelpTopic(
            summary: "Migrate a root-owned core to the user-level agent.",
            usage: ["kumo agent migrate [--dry-run] [--json]"],
            options: ["--dry-run       Report the current tier and planned handoff without migrating."],
            example: "kumo agent migrate --dry-run --json",
            details: ["The core must not be migrated while TUN is enabled. Install the agent first; this command never installs it."]
        ),
        "providers": HelpTopic(
            summary: "Show proxy and rule providers, or update them.",
            usage: [
                "kumo providers [--json]",
                "kumo providers update --proxy <name> [--json]",
                "kumo providers update --rule <name> [--json]",
                "kumo providers update --geo [--json]"
            ],
            example: "kumo providers update --geo --json"
        ),
        "test": HelpTopic(
            summary: "Test proxy or group latency.",
            usage: ["kumo test <proxy|group> [--url <url>] [--json]"],
            example: "kumo test Proxy --json",
            details: ["A name matching a proxy group tests every member of the group; otherwise it is tested as a single proxy. --url applies to single-proxy tests."]
        ),
        "logs": HelpTopic(
            summary: "Show or follow Kumo logs.",
            usage: [
                "kumo logs [runtime] [--limit <count>] [--level <level>] [--json]",
                "kumo logs --follow [--level <level>] [--json]",
                "kumo logs cli [--limit <count>] [--level <level>] [--json]",
                "kumo logs path",
                "kumo logs clean [--dry-run] [--json]"
            ],
            example: "kumo logs --follow --level info",
            details: [
                "--limit caps the number of log entries printed. --follow streams new entries until Ctrl-C; with --json it writes one envelope per line (NDJSON)."
            ]
        ),
        "logs runtime": HelpTopic(
            summary: "Show recent Mihomo runtime logs.",
            usage: ["kumo logs [runtime] [--limit <count>] [--level <level>] [--json]"],
            options: ["--limit <count>   Maximum number of log lines. (default: 100)"],
            example: "kumo logs runtime --limit 20 --json"
        ),
        "logs cli": HelpTopic(
            summary: "Show recent Kumo CLI debug log entries.",
            usage: ["kumo logs cli [--limit <count>] [--level <level>] [--json]"],
            options: ["--limit <count>   Maximum number of log entries to print. (default: 20)"],
            example: "kumo logs cli --limit 5 --json",
            details: ["--limit counts log entries, not files; the newest entries are printed first. --level filters to entries at or above the given level before the limit is applied."]
        ),
        "traffic": HelpTopic(
            summary: "Watch live Mihomo traffic counters.",
            usage: ["kumo traffic --watch [--json]"],
            example: "kumo traffic --watch --json",
            details: ["Traffic is only available as a live stream. With --json it writes one envelope per line (NDJSON); Ctrl-C exits cleanly."]
        ),
        "connections": HelpTopic(
            summary: "List or close active connections.",
            usage: [
                "kumo connections [--json]",
                "kumo connections --close <id> [--json]",
                "kumo connections --close-all [--json]"
            ],
            options: [
                "--close <id>    Close a specific connection id.",
                "--close-all     Close all active connections."
            ],
            example: "kumo connections --json"
        ),
        "backup": HelpTopic(
            summary: "Export or import Kumo backup data.",
            usage: [
                "kumo backup export <path> [--json]",
                "kumo backup import <path> [--json]"
            ],
            example: "kumo backup export /tmp/kumo-backup --json"
        ),
        "core": HelpTopic(
            summary: "Manage the managed Mihomo core.",
            usage: ["kumo core install [--json]"],
            example: "kumo core install --json",
            details: ["Installs the managed Mihomo core that `kumo start` runs."]
        ),
        "config": HelpTopic(
            summary: "Show Kumo paths and runtime settings.",
            usage: [
                "kumo config [path] [--json]",
                "kumo config list [--json]",
                "kumo config get [<key>] [--json]",
                "kumo config set [<options>] [--dry-run] [--json]",
                "kumo config secret [--set <secret>] [--json]"
            ],
            example: "kumo config get --json",
            details: [
                "`config path` prints the application support directory; `config list` prints every CLI-visible path.",
                "`config get` prints the stored CoreRuntimeSettings object or one key. `config set` owns mixedPort, allowLan, logLevel, ipv6, and findProcessMode; DNS, sniffer, and TUN settings use `kumo dns`, `kumo sniffer`, and `kumo tun`. `config secret` reports or replaces the controller secret without printing it."
            ]
        ),
        "config get": HelpTopic(
            summary: "Print stored runtime settings.",
            usage: [
                "kumo config get [--json]",
                "kumo config get <mixedPort|allowLan|logLevel|ipv6|findProcessMode|geoData> [--json]"
            ],
            example: "kumo config get mixedPort --json",
            details: ["Unknown keys fail with the list of valid keys. DNS, sniffer, and TUN settings have dedicated commands."]
        ),
        "config set": HelpTopic(
            summary: "Update core runtime settings.",
            usage: [
                "kumo config set --mixed-port <port> [--allow-lan <bool>] [--log-level <level>] [--ipv6 <bool>] [--find-process-mode <mode>] [--dry-run] [--json]",
                "kumo config set --file <path> [--dry-run] [--json]",
                "kumo config set --stdin [--dry-run] [--json]"
            ],
            example: "kumo config set --mixed-port 7897 --dry-run --json",
            details: [
                "`mixedPort` must be 1...65535, `logLevel` one of silent|error|warning|info|debug, and `findProcessMode` one of always|strict|off. A JSON patch rejects unknown top-level keys with the list of valid ones; dns, sniffer, and tun point at their dedicated commands. --dry-run prints the merged settings without writing."
            ]
        ),
        "config secret": HelpTopic(
            summary: "Show or replace the controller secret.",
            usage: [
                "kumo config secret [--json]",
                "kumo config secret --set <secret> [--json]"
            ],
            example: "kumo config secret --json",
            details: ["The stored secret is never printed; the command reports set=true|false. A new secret takes effect the next time the core starts, not on a running core."]
        ),
        "doctor": HelpTopic(
            summary: "Inspect runtime, profile, and core candidates.",
            usage: ["kumo doctor [--json]"],
            example: "kumo doctor --json"
        ),
        "runtime-events": HelpTopic(
            summary: "Show recent Kumo runtime events.",
            usage: ["kumo runtime-events [--limit <count>] [--json]"],
            options: ["--limit <count>   Maximum number of events. (default: 100)"],
            example: "kumo runtime-events --limit 20 --json"
        ),
        "substore": HelpTopic(
            summary: "Manage bundled Sub-Store resources and runtime.",
            usage: [
                "kumo substore status [--json]",
                "kumo substore prepare [--json]",
                "kumo substore start|stop|restart [--json]"
            ],
            example: "kumo substore status --json",
            details: ["`prepare` installs or refreshes the bundled Sub-Store resources before the backend is started."]
        ),
        "skills": HelpTopic(
            summary: "Manage bundled Kumo agent skills.",
            usage: [
                "kumo skills status [--agent <agent|all>] [--scope <global|project>] [--json]",
                "kumo skills install [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--force] [--json]",
                "kumo skills uninstall [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--json]"
            ],
            options: [
                "--agent <cursor|claude|codex|gemini|agents|all>",
                "--scope <global|project>",
                "--dry-run",
                "--force"
            ],
            example: "kumo skills install --agent all --dry-run --json",
            details: ["`skills install` is also available as `kumo skills add`."]
        ),
        "skills install": HelpTopic(
            summary: "Install bundled Kumo agent skills.",
            usage: ["kumo skills install [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--force] [--json]"],
            options: [
                "--agent <cursor|claude|codex|gemini|agents|all>",
                "--scope <global|project>",
                "--dry-run",
                "--force"
            ],
            example: "kumo skills install --agent codex --dry-run --json",
            details: ["alias: add"]
        ),
        "completion": HelpTopic(
            summary: "Generate shell completion scripts.",
            usage: ["kumo completion <zsh|bash|fish>"],
            example: "kumo completion zsh > ~/.zsh/completions/_kumo",
            details: ["The word list is derived from the live command tree, aliases included."]
        ),
        "help": HelpTopic(
            summary: "Show detailed help for a topic.",
            usage: [
                "kumo help <term>",
                "kumo help <command> <subcommand>"
            ],
            example: "kumo help status",
            details: ["Use `kumo -l` to list every command with its usage, or `kumo <command> -h` for generated option help."]
        )
    ]
}
