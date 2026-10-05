import ArgumentParser

/// Read-only view of the Kumo command tree.
///
/// Every entry is derived from `KumoCommand.configuration.subcommands`, so the
/// top-level help, the long listing, the help topics, and the completion word
/// list cannot drift from the commands that actually register with
/// ArgumentParser.
enum CommandIndex {
    struct Entry {
        let type: ParsableCommand.Type
        let name: String
        let path: [String]
        let abstract: String
        let aliases: [String]
        let children: [Entry]

        var commandPath: String { path.joined(separator: " ") }
        var isLeaf: Bool { children.isEmpty }

        /// All descendant entries, depth-first.
        var descendants: [Entry] {
            children + children.flatMap(\.descendants)
        }
    }

    /// Every node in the tree, depth-first in declaration order.
    static let all: [Entry] = entries(for: KumoCommand.configuration.subcommands, parentPath: [])

    /// The canonical commands shown by `kumo -h`.
    static let topLevel: [Entry] = all.filter { $0.path.count == 1 }

    /// Commands with no subcommands; these are the runnable leaves.
    static let leaves: [Entry] = all.filter(\.isLeaf)

    /// Top-level command names plus their aliases, sorted and deduplicated.
    static let completionWords: [String] = {
        let names = topLevel.flatMap { [$0.name] + $0.aliases }
        return Array(Set(names)).sorted()
    }()

    /// Resolves a typed command path, accepting aliases at every level.
    static func entry(forPath names: [String]) -> Entry? {
        var entries = all
        var match: Entry?
        for name in names {
            guard let next = entries.first(where: { $0.name == name || $0.aliases.contains(name) }) else {
                return nil
            }
            match = next
            entries = next.children
        }
        return match
    }

    private static func entries(for types: [ParsableCommand.Type], parentPath: [String]) -> [Entry] {
        types.map { type in
            let name = type._commandName
            let path = parentPath + [name]
            return Entry(
                type: type,
                name: name,
                path: path,
                abstract: type.configuration.abstract,
                aliases: type.configuration.aliases,
                children: entries(for: type.configuration.subcommands, parentPath: path)
            )
        }
    }
}
