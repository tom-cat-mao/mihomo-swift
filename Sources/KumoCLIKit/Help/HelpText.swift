import Foundation

enum HelpText {
    /// Short help (`kumo -h`) with the common task list and the full set of
    /// top-level command names, derived from the live command tree.
    static var topLevel: String {
        """
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

        \(wrappedCommandList())

        Kumo CLI binary:
            Kumo.app/Contents/Helpers/kumo

        Installed command:
            /usr/local/bin/kumo -> Kumo.app/Contents/Helpers/kumo

        kumo@\(KumoCommand.configuration.version)
        """
    }

    /// Long help (`kumo -l`) with one section per top-level command. The
    /// command list, paths, abstracts, and aliases all come from
    /// `CommandIndex`, so every registered command is listed here no matter
    /// how the tree changes.
    static var long: String {
        var sections: [String] = [topLevel]
        for entry in CommandIndex.topLevel.sorted(by: { $0.name < $1.name }) {
            sections.append(longSection(for: entry))
        }
        return sections.joined(separator: "\n\n")
    }

    static let completion = """
    Tab Completion for kumo

    Usage:
    kumo completion <zsh|bash|fish>

    Examples:
    kumo completion zsh > ~/.zsh/completions/_kumo
    kumo completion bash > /usr/local/etc/bash_completion.d/kumo
    """

    /// Detailed help for `kumo help <term>`.
    static func topic(_ terms: [String]) -> String {
        let normalized = terms.map { $0.lowercased() }
        let key = normalized.joined(separator: " ")
        switch key {
        case "", "kumo":
            return topLevel
        case "json":
            return jsonTopic
        default:
            break
        }

        guard let entry = CommandIndex.entry(forPath: normalized) else {
            return "No detailed help found for \(key).\nRun \"kumo -l\" to list all commands."
        }
        if let topic = HelpTopics.byPath[entry.commandPath] {
            return render(topic, for: entry)
        }
        return synthesizedTopic(for: entry)
    }

    // MARK: - Rendering

    private static let continuationIndent = String(repeating: " ", count: 20)

    private static func wrappedCommandList() -> String {
        let names = CommandIndex.topLevel.map(\.name).sorted()
        let width = 72
        var lines: [String] = []
        var current = ""
        for name in names {
            let candidate = current.isEmpty ? name : current + ", " + name
            if !current.isEmpty, candidate.count + 4 > width {
                lines.append("    " + current + ",")
                current = name
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            lines.append("    " + current)
        }
        return lines.joined(separator: "\n")
    }

    private static func longSection(for entry: CommandIndex.Entry) -> String {
        let topic = HelpTopics.byPath[entry.commandPath]
        var lines = [entry.name.padding(toLength: 16, withPad: " ", startingAt: 0) + entry.abstract]
        if !entry.aliases.isEmpty {
            lines.append(continuationIndent + "aliases: " + entry.aliases.joined(separator: ", "))
        }
        if !entry.children.isEmpty {
            let descendants = entry.descendants.map(\.commandPath).sorted()
            lines.append(continuationIndent + "Commands: " + descendants.joined(separator: ", "))
        }
        let usage = topic?.usage ?? generatedUsage(for: entry)
        if !usage.isEmpty {
            lines.append(continuationIndent + "Usage:")
            lines.append(contentsOf: usage.map { continuationIndent + $0 })
        }
        lines.append(continuationIndent + "Run \"kumo help \(entry.commandPath)\" for more info")
        return lines.joined(separator: "\n")
    }

    private static func render(_ topic: HelpTopic, for entry: CommandIndex.Entry) -> String {
        var sections: [String] = [
            entry.commandPath,
            topic.summary,
            "",
            "Usage:",
            topic.usage.joined(separator: "\n")
        ]
        if !topic.options.isEmpty {
            sections.append("")
            sections.append("Options:")
            sections.append(topic.options.joined(separator: "\n"))
        }
        sections.append("")
        sections.append("Example:")
        sections.append(topic.example)
        for detail in topic.details {
            sections.append("")
            sections.append(detail)
        }
        if !entry.aliases.isEmpty {
            sections.append("")
            sections.append("aliases: " + entry.aliases.joined(separator: ", "))
        }
        return sections.joined(separator: "\n")
    }

    private static func synthesizedTopic(for entry: CommandIndex.Entry) -> String {
        var sections: [String] = [entry.commandPath, entry.abstract]
        let usage = generatedUsage(for: entry)
        if !usage.isEmpty {
            sections.append("")
            sections.append("Usage:")
            sections.append(usage.joined(separator: "\n"))
        }
        if let parent = CommandIndex.topLevel.first(where: { entry.path.starts(with: $0.path) }), parent.path.count < entry.path.count {
            sections.append("")
            sections.append("Run \"kumo help \(parent.commandPath)\" for the command overview.")
        }
        return sections.joined(separator: "\n")
    }

    private static func generatedUsage(for entry: CommandIndex.Entry) -> [String] {
        let usage = KumoCommand.usageString(for: entry.type)
        return usage.isEmpty ? [] : [usage]
    }

    private static let jsonTopic = """
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
}

enum CompletionScripts {
    /// Top-level command names plus aliases, derived from the command tree.
    static var commandNames: String {
        CommandIndex.completionWords.joined(separator: " ")
    }

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
