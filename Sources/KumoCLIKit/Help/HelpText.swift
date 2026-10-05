enum HelpText {
    static let topLevel = """
    kumo <command>

    Usage:

    kumo status --json          show current Kumo runtime state
    kumo start                  start Kumo with the managed Mihomo core
    kumo doctor --json          inspect runtime, profile, and core candidates
    kumo proxies                list proxy groups and selected proxies
    kumo rules --json           list Mihomo rules with enabled state
    kumo dns --json             show DNS runtime settings
    kumo agent status --json    show user-level agent (kumod) state
    kumo skills install --dry-run --json
                                 preview agent skill installation
    kumo <command> -h           quick help on a command
    kumo -l                     display usage info for all commands
    kumo help <term>            show detailed help for a topic

    All commands:

        agent, backup, completion, config, connections, core, dns,
        doctor, help, logs, mode, profile, providers, proxies, restart,
        rules, service, skills, sniffer, start, status, stop, substore,
        sysproxy, test, traffic, tun, runtime-events

    Kumo CLI binary:
        Kumo.app/Contents/Helpers/kumo

    Installed command:
        /usr/local/bin/kumo -> Kumo.app/Contents/Helpers/kumo

    kumo@0.0.1
    """

    static let long = """
    \(topLevel)

    status          Show current Kumo runtime state

                    Usage:
                    kumo status [--json]

                    Options:
                    [--json] [--color <always|auto|never>]
                    [--loglevel <silent|error|warn|notice|http|info|verbose|silly>]

                    aliases: st

                    Run "kumo help status" for more info

    rules           List Mihomo rules or toggle one by index

                    Usage:
                    kumo rules [--json]
                    kumo rules enable <index> [--json]
                    kumo rules disable <index> [--json]

                    Run "kumo help rules" for more info

    profile         Manage profiles

                    Usage:
                    kumo profile list [--json]
                    kumo profile use <id> [--json]
                    kumo profile delete <id> [--dry-run] [--json]
                    kumo profile import <path> [--json]
                    kumo profile content <id> [--json]
                    kumo profile refresh <url> [--json]

                    Run "kumo help profile" for more info

    dns             Show or update DNS runtime settings

                    Usage:
                    kumo dns [--json]
                    kumo dns enable|disable [--json]
                    kumo dns set --file <path>|--stdin [--dry-run] [--json]

                    Run "kumo help dns" for more info

    sniffer         Show or update sniffer runtime settings

                    Usage:
                    kumo sniffer [--json]
                    kumo sniffer enable|disable [--json]
                    kumo sniffer set --file <path>|--stdin [--dry-run] [--json]

                    Run "kumo help sniffer" for more info

    agent           Manage the user-level Kumo agent (kumod)

                    Usage:
                    kumo agent status [--json]
                    kumo agent install [--dry-run] [--json]
                    kumo agent uninstall [--dry-run] [--json]
                    kumo agent migrate [--dry-run] [--json]

                    Run "kumo help agent" for more info

    traffic         Watch live Mihomo traffic counters

                    Usage:
                    kumo traffic --watch [--json]

                    Run "kumo help traffic" for more info

    skills          Manage bundled Kumo agent skills

                    Usage:
                    kumo skills status [--agent <agent|all>] [--scope <global|project>] [--json]
                    kumo skills install [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--force] [--json]
                    kumo skills uninstall [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--json]

                    Options:
                    [--agent <cursor|claude|codex|gemini|agents|all>]
                    [--scope <global|project>] [--dry-run] [--force] [--json]

                    Run "kumo help skills" for more info
    """

    static let completion = """
    Tab Completion for kumo

    Usage:
    kumo completion <zsh|bash|fish>

    Examples:
    kumo completion zsh > ~/.zsh/completions/_kumo
    kumo completion bash > /usr/local/etc/bash_completion.d/kumo
    """

    static func topic(_ terms: [String]) -> String {
        let key = terms.joined(separator: " ")
        switch key {
        case "", "kumo":
            return topLevel
        case "json":
            return """
            Kumo JSON output

            Usage:
            kumo <command> --json

            Successful commands write:
            {
              "data": {},
              "error": null,
              "ok": true
            }

            Failed commands write:
            {
              "data": null,
              "error": "message",
              "ok": false
            }

            Streaming commands (kumo logs --follow, kumo traffic --watch) write one
            compact envelope per line (NDJSON).

            JSON output is written to stdout. Human-readable errors are written to stderr only when --json is not used.
            Exit code 0 means success. Exit code 1 means failure.
            """
        case "rules":
            return """
            List Mihomo rules or toggle one by index

            Usage:
            kumo rules [--json]
            kumo rules enable <index> [--json]
            kumo rules disable <index> [--json]

            Indexes match the index shown by `kumo rules`.
            """
        case "profile":
            return """
            Manage profiles

            Usage:
            kumo profile list [--json]
            kumo profile use <id> [--json]
            kumo profile delete <id> [--dry-run] [--json]
            kumo profile import <path|file-url> [--json]
            kumo profile content <id> [--json]
            kumo profile refresh <url> [--json]

            `profile import` imports a local YAML file. Remote subscriptions use
            `profile refresh`.
            """
        case "dns":
            return """
            Show or update DNS runtime settings

            Usage:
            kumo dns [--json]
            kumo dns enable [--json]
            kumo dns disable [--json]
            kumo dns set --file <path> [--dry-run] [--json]
            kumo dns set --stdin [--dry-run] [--json]

            `dns set` reads a JSON object whose keys match DnsSettings. Only the
            provided keys are changed; the core restarts when settings are applied
            while running. Use --dry-run to preview the merged settings.
            """
        case "sniffer":
            return """
            Show or update sniffer runtime settings

            Usage:
            kumo sniffer [--json]
            kumo sniffer enable [--json]
            kumo sniffer disable [--json]
            kumo sniffer set --file <path> [--dry-run] [--json]
            kumo sniffer set --stdin [--dry-run] [--json]

            `sniffer set` reads a JSON object whose keys match SnifferSettings.
            Only the provided keys are changed; the core restarts when settings are
            applied while running.
            """
        case "tun", "tun settings":
            return """
            Manage TUN state and settings

            Usage:
            kumo tun status [--json]
            kumo tun enable [--json]
            kumo tun disable [--json]
            kumo tun settings [--json]
            kumo tun settings --file <path> [--dry-run] [--json]
            kumo tun settings --stdin [--dry-run] [--json]

            `tun settings` without input prints the current settings; with
            --file/--stdin it merges a JSON object whose keys match TunSettings.
            """
        case "sysproxy":
            return """
            Control macOS system proxy

            Usage:
            kumo sysproxy on [--dry-run] [--json]
            kumo sysproxy off [--dry-run] [--json]
            kumo sysproxy set --bypass <comma-list> [--network-service <name>] [--host <host>] [--port <port>] [--mode manual|pac] [--dry-run] [--json]
            kumo sysproxy set --file <path> [--dry-run] [--json]
            kumo sysproxy set --stdin [--dry-run] [--json]

            `sysproxy set` updates stored settings and re-applies them when the
            system proxy is currently enabled.
            """
        case "providers":
            return """
            Show proxy and rule providers, or update them

            Usage:
            kumo providers [--json]
            kumo providers update --proxy <name> [--json]
            kumo providers update --rule <name> [--json]
            kumo providers update --geo [--json]
            """
        case "test":
            return """
            Test proxy or group latency

            Usage:
            kumo test <proxy|group> [--url <url>] [--json]

            A name matching a proxy group tests every member of the group;
            otherwise it is tested as a single proxy. --url applies to
            single-proxy tests.
            """
        case "logs", "logs runtime", "logs follow":
            return """
            Show or follow Kumo logs

            Usage:
            kumo logs [runtime] [--limit <count>] [--level <level>] [--json]
            kumo logs --follow [--level <level>] [--json]
            kumo logs cli [--limit <count>] [--level <level>] [--json]
            kumo logs path
            kumo logs clean [--dry-run] [--json]

            --follow streams new entries until Ctrl-C; with --json it writes one
            envelope per line (NDJSON).
            """
        case "traffic":
            return """
            Watch live Mihomo traffic counters

            Usage:
            kumo traffic --watch [--json]

            Traffic is only available as a live stream. With --json it writes one
            envelope per line (NDJSON); Ctrl-C exits cleanly.
            """
        case "agent":
            return """
            Manage the user-level Kumo agent (kumod)

            Usage:
            kumo agent status [--json]
            kumo agent install [--dry-run] [--json]
            kumo agent uninstall [--dry-run] [--json]
            kumo agent migrate [--dry-run] [--json]

            The user agent (io.kumo.KumoAgent) owns the Mihomo core so it keeps
            running when the Kumo app quits. It starts on demand and exits after
            an idle timeout. `agent status` uses the same shape as `service status`.

            `agent migrate` hands a running root-owned core to the user agent so
            the privileged daemon no longer owns it. It refuses while TUN is
            enabled (the core must stay root-owned) and until the agent is
            installed. --dry-run reports the installed tiers, the current core
            owner, and the planned handoff without stopping or starting anything.
            """
        case "skills", "skills install":
            return """
            Install bundled Kumo agent skills

            Usage:
            kumo skills install [--agent <agent|all>] [--scope <global|project>] [--dry-run] [--force] [--json]

            Options:
            [--agent <cursor|claude|codex|gemini|agents|all>]
            [--scope <global|project>]
            [--dry-run]
            [--force]
            [--json]

            alias: add

            Run "kumo help skills install" for more info
            """
        default:
            return "No detailed help found for \(key).\nRun \"kumo --help\" for more info."
        }
    }
}

enum CompletionScripts {
    static let commandNames = "status start stop restart mode proxies proxy select rules test logs traffic connections providers runtime-events doctor config c backup core profile dns sniffer sysproxy service tun agent substore skills completion help"

    static func script(for shell: CompletionShell) -> String {
        switch shell {
        case .zsh:
            return """
            #compdef kumo
            # Generated completion script for kumo
            _arguments '1: :((\(commandNames)))'
            """
        case .bash:
            return """
            # Generated completion script for kumo
            complete -W "\(commandNames)" kumo
            """
        case .fish:
            return """
            # Generated completion script for kumo
            complete -c kumo -f -a "\(commandNames)"
            """
        }
    }
}
