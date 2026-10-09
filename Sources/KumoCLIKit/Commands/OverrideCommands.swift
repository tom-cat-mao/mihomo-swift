import ArgumentParser
import Foundation
import KumoCoreKit

extension KumoCommand {
    struct Override: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage runtime config overrides.",
            subcommands: [List.self, Content.self, Add.self, Update.self, Delete.self, Reorder.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List overrides in merge order.")

            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let entries = OverrideCommandSupport.listEntries(try CLIRuntime.current.controller.overrides())
                CLIRuntime.current.write(entries) { entries in
                    entries.map { entry in
                        var line = "\(entry.index) \(entry.id) \(entry.format) \(entry.kind) \(entry.name)"
                        if entry.isGlobal { line += " [global]" }
                        if let remoteURL = entry.remoteURL { line += " \(remoteURL)" }
                        return line
                    }.joined(separator: "\n")
                }
            }
        }

        struct Content: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Print an override's body.")

            @Argument(help: "Override id shown by `kumo override list`.")
            var id: String
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let payload = try OverrideCommandSupport.content(
                    controller: CLIRuntime.current.controller,
                    id: id
                )
                CLIRuntime.current.write(payload) { $0.content }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a local or remote override.",
                discussion: "Local overrides read --file <path> or --stdin; remote overrides fetch --url directly, without the proxy. Overrides merge into the runtime config on the next core start; --restart restarts a running core to apply the change immediately."
            )

            @Option(name: .long, help: "Read the override body from a local file.")
            var file: String?
            @Flag(name: .long, help: "Read the override body from stdin.")
            var stdin = false
            @Option(name: .long, help: "Fetch a remote override from this URL (direct connection, no proxy).")
            var url: String?
            @Option(name: .long, help: "Override name. Required for local overrides.")
            var name: String?
            @Option(name: .long, help: "Override format: yaml (applied to the runtime config) or js (stored only).")
            var format: OverrideFormatOption = .yaml
            @Flag(name: .long, help: "Mark the override global (stored; global overrides are not applied to the runtime config yet).")
            var global = false
            @Flag(name: .long, help: "Restart the core when it is running so the override takes effect now.")
            var restart = false
            @Flag(name: .long, help: "Validate the local override without writing it.")
            var dryRun = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if let name, name.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ValidationError("The override name must not be empty.")
                }
                if let url {
                    guard file == nil, !stdin else {
                        throw ValidationError("Use --url for a remote override or --file/--stdin for a local override, not both.")
                    }
                    guard !dryRun else {
                        throw ValidationError("--dry-run applies to local overrides only.")
                    }
                    guard let parsed = URL(string: url),
                          let scheme = parsed.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else {
                        throw ValidationError("Invalid override URL: \(url)")
                    }
                } else {
                    if file != nil && stdin {
                        throw ValidationError("Use either --file <path> or --stdin, not both.")
                    }
                    if file == nil && !stdin {
                        throw ValidationError("Provide --url <url> for a remote override, or --file <path>/--stdin for a local override.")
                    }
                    guard name != nil else {
                        throw ValidationError("Provide --name <name> for a local override.")
                    }
                }
                if dryRun && restart {
                    throw ValidationError("--dry-run cannot be combined with --restart.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let controller = CLIRuntime.current.controller

                if let url {
                    guard let parsedURL = URL(string: url) else {
                        throw ValidationError("Invalid override URL: \(url)")
                    }
                    let report = try await OverrideCommandSupport.addRemote(
                        controller: controller,
                        url: parsedURL,
                        name: name,
                        format: format.overrideFormat,
                        isGlobal: global,
                        restart: restart
                    )
                    writeOverrideReport(report, warnings: report.warnings) { report in
                        "added remote override \(report.name) (\(report.id ?? "-")); \(overrideEffectText(report))"
                    }
                    return
                }

                guard let name else {
                    throw ValidationError("Provide --name <name> for a local override.")
                }
                let body = try readOverrideBody(file: file, stdin: stdin)
                let report = try OverrideCommandSupport.addLocal(
                    controller: controller,
                    name: name,
                    content: body,
                    format: format.overrideFormat,
                    isGlobal: global,
                    dryRun: dryRun,
                    restart: restart
                )
                writeOverrideReport(report, warnings: report.warnings) { report in
                    report.dryRun
                        ? "[dry-run] would add override \(report.name) (\(report.format)); no changes written"
                        : "added override \(report.name) (\(report.id ?? "-")); \(overrideEffectText(report))"
                }
            }
        }

        struct Update: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Replace an override's body.",
                discussion: "Keeps the item's name, kind, format, and flags. Applies on the next core start; --restart restarts a running core to apply the change immediately."
            )

            @Argument(help: "Override id shown by `kumo override list`.")
            var id: String
            @Option(name: .long, help: "Read the new override body from a local file.")
            var file: String?
            @Flag(name: .long, help: "Read the new override body from stdin.")
            var stdin = false
            @Flag(name: .long, help: "Restart the core when it is running so the override takes effect now.")
            var restart = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if file != nil && stdin {
                    throw ValidationError("Use either --file <path> or --stdin, not both.")
                }
                if file == nil && !stdin {
                    throw ValidationError("Provide --file <path> or --stdin with the new override body.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let body = try readOverrideBody(file: file, stdin: stdin)
                let report = try OverrideCommandSupport.update(
                    controller: CLIRuntime.current.controller,
                    id: id,
                    content: body,
                    restart: restart
                )
                writeOverrideReport(report, warnings: report.warnings) { report in
                    "updated override \(report.id ?? id); \(overrideEffectText(report))"
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete an override.",
                discussion: "Unknown ids fail instead of silently doing nothing. Applies on the next core start; --restart restarts a running core to apply the change immediately."
            )

            @Argument(help: "Override id shown by `kumo override list`.")
            var id: String
            @Flag(name: .long, help: "Preview the deletion without writing.")
            var dryRun = false
            @Flag(name: .long, help: "Restart the core when it is running so the override takes effect now.")
            var restart = false
            @OptionGroup var options: CLIOptions

            mutating func validate() throws {
                if dryRun && restart {
                    throw ValidationError("--dry-run cannot be combined with --restart.")
                }
            }

            mutating func run() async throws {
                try options.install()
                let report = try OverrideCommandSupport.delete(
                    controller: CLIRuntime.current.controller,
                    id: id,
                    dryRun: dryRun,
                    restart: restart
                )
                writeOverrideReport(report, warnings: []) { report in
                    report.dryRun
                        ? "[dry-run] would delete override \(report.name) (\(report.id))"
                        : "deleted override \(report.id); \(overrideEffectText(report))"
                }
            }
        }

        struct Reorder: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Reorder overrides by id.",
                discussion: "Moves the listed ids to the front in the given order; unlisted ids keep their relative order after them. Applies on the next core start; --restart restarts a running core to apply the change immediately."
            )

            @Option(name: .long, help: "Comma-separated override ids in the new order.")
            var ids: String
            @Flag(name: .long, help: "Restart the core when it is running so the override takes effect now.")
            var restart = false
            @OptionGroup var options: CLIOptions

            mutating func run() async throws {
                try options.install()
                let report = try OverrideCommandSupport.reorder(
                    controller: CLIRuntime.current.controller,
                    ids: ids,
                    restart: restart
                )
                writeOverrideReport(report, warnings: []) { report in
                    "reordered overrides: \(report.ids.joined(separator: ", ")); \(overrideEffectText(report))"
                }
            }
        }
    }
}

/// `--format` values accepted by `kumo override add`.
enum OverrideFormatOption: String, ExpressibleByArgument, CaseIterable {
    case yaml
    case js

    var overrideFormat: OverrideFormat {
        switch self {
        case .yaml: .yaml
        case .js: .javascript
        }
    }
}

/// Execution helpers shared by the `kumo override` subcommands.
///
/// They take a `KumoController` directly instead of reading
/// `CLIRuntime.current`, so tests can exercise the full mutation flow against
/// a hermetic app-support directory.
enum OverrideCommandSupport {
    /// Formats an override format for CLI output: `js` for `.javascript`,
    /// matching the `--format` argument.
    static func displayFormat(_ format: OverrideFormat) -> String {
        format == .yaml ? "yaml" : "js"
    }

    static func listEntries(_ items: [OverrideItem]) -> [OverrideListEntry] {
        items.enumerated().map { index, item in
            OverrideListEntry(
                index: index,
                id: item.id,
                name: item.name,
                format: displayFormat(item.format),
                kind: item.kind.rawValue,
                isGlobal: item.isGlobal,
                remoteURL: item.remoteURL?.absoluteString
            )
        }
    }

    static func content(controller: KumoController, id: String) throws -> OverrideContentPayload {
        _ = try existingItem(controller: controller, id: id)
        return OverrideContentPayload(id: id, content: try controller.overrideContent(id: id))
    }

    static func addLocal(
        controller: KumoController,
        name: String,
        content: String,
        format: OverrideFormat,
        isGlobal: Bool,
        dryRun: Bool,
        restart: Bool
    ) throws -> OverrideMutationReport {
        let warnings = addWarnings(format: format, isGlobal: isGlobal)
        if dryRun {
            if format == .yaml {
                try validateYAML(content)
            }
            return OverrideMutationReport(
                id: nil,
                name: name,
                format: displayFormat(format),
                kind: OverrideKind.local.rawValue,
                isGlobal: isGlobal,
                dryRun: true,
                warnings: warnings,
                restartRequested: false,
                restarted: false
            )
        }

        let item = try controller.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
        let restarted = try restartCoreIfRunning(controller: controller, requested: restart)
        return mutationReport(item: item, warnings: warnings, restartRequested: restart, restarted: restarted)
    }

    static func addRemote(
        controller: KumoController,
        url: URL,
        name: String?,
        format: OverrideFormat,
        isGlobal: Bool,
        restart: Bool
    ) async throws -> OverrideMutationReport {
        let warnings = addWarnings(format: format, isGlobal: isGlobal)
        let item = try await controller.addRemoteOverride(url: url, name: name, format: format, isGlobal: isGlobal)
        let restarted = try restartCoreIfRunning(controller: controller, requested: restart)
        return mutationReport(item: item, warnings: warnings, restartRequested: restart, restarted: restarted)
    }

    static func update(controller: KumoController, id: String, content: String, restart: Bool) throws -> OverrideMutationReport {
        let item = try existingItem(controller: controller, id: id)
        try controller.updateOverride(item, content: content)
        let restarted = try restartCoreIfRunning(controller: controller, requested: restart)
        return mutationReport(item: item, warnings: [], restartRequested: restart, restarted: restarted)
    }

    static func delete(controller: KumoController, id: String, dryRun: Bool, restart: Bool) throws -> OverrideDeleteReport {
        let item = try existingItem(controller: controller, id: id)
        if dryRun {
            return OverrideDeleteReport(
                id: id,
                name: item.name,
                dryRun: true,
                restartRequested: false,
                restarted: false
            )
        }
        try controller.deleteOverride(id: id)
        let restarted = try restartCoreIfRunning(controller: controller, requested: restart)
        return OverrideDeleteReport(
            id: id,
            name: item.name,
            dryRun: false,
            restartRequested: restart,
            restarted: restarted
        )
    }

    static func reorder(controller: KumoController, ids rawIDs: String, restart: Bool) throws -> OverrideReorderReport {
        let ids = parseIDList(rawIDs)
        guard !ids.isEmpty else {
            throw ValidationError("Provide at least one override id via --ids <id1,id2,...>.")
        }
        var seen = Set<String>()
        if let duplicate = ids.first(where: { !seen.insert($0).inserted }) {
            throw ValidationError("Duplicate override id in --ids: \(duplicate)")
        }
        let existing = Set(try controller.overrides().map(\.id))
        for id in ids where !existing.contains(id) {
            throw ValidationError("Unknown override id: \(id)")
        }
        try controller.reorderOverrides(ids: ids)
        let restarted = try restartCoreIfRunning(controller: controller, requested: restart)
        return OverrideReorderReport(ids: ids, restartRequested: restart, restarted: restarted)
    }

    /// Restarts the core when `--restart` was passed and the core is running.
    /// A stopped core is a no-op: `KumoController.restart()` would otherwise
    /// launch a core instead of refreshing one.
    static func restartCoreIfRunning(controller: KumoController, requested: Bool) throws -> Bool {
        let isRunning = try controller.status().state == .running
        return try restartCore(requested: requested, isRunning: isRunning) {
            _ = try controller.restart()
        }
    }

    /// Decision seam for `restartCoreIfRunning`; `perform` runs only when both
    /// `requested` and `isRunning` are true.
    static func restartCore(requested: Bool, isRunning: Bool, perform: () throws -> Void) rethrows -> Bool {
        guard requested, isRunning else { return false }
        try perform()
        return true
    }

    /// Audit-driven caveats surfaced on `add`: JS bodies are stored but never
    /// merged, and `isGlobal` has no runtime effect yet.
    static func addWarnings(format: OverrideFormat, isGlobal: Bool) -> [String] {
        var warnings: [String] = []
        if format == .javascript {
            warnings.append("JavaScript overrides are stored but never merged; only YAML overrides are applied.")
        }
        if isGlobal {
            warnings.append("Global overrides are stored but are not applied to the runtime config yet.")
        }
        return warnings
    }

    /// Parses the body with the same YAML loader the runtime config builder
    /// uses, so `--dry-run` fails on exactly the documents the core launch
    /// would reject.
    static func validateYAML(_ content: String) throws {
        let profile = Profile(name: "override-validation", source: .inline, rawYAML: "")
        do {
            _ = try RuntimeConfigBuilder().build(profile: profile, overrideYAMLs: [content])
        } catch {
            throw ValidationError("The override YAML is invalid: \(error.localizedDescription)")
        }
    }

    static func parseIDList(_ rawIDs: String) -> [String] {
        rawIDs
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func existingItem(controller: KumoController, id: String) throws -> OverrideItem {
        guard let item = try controller.overrides().first(where: { $0.id == id }) else {
            throw ValidationError("Unknown override id: \(id)")
        }
        return item
    }

    private static func mutationReport(
        item: OverrideItem,
        warnings: [String],
        restartRequested: Bool,
        restarted: Bool
    ) -> OverrideMutationReport {
        OverrideMutationReport(
            id: item.id,
            name: item.name,
            format: displayFormat(item.format),
            kind: item.kind.rawValue,
            isGlobal: item.isGlobal,
            dryRun: false,
            warnings: warnings,
            restartRequested: restartRequested,
            restarted: restarted
        )
    }
}

/// Reads an override body from `--file <path>` or stdin. Callers validate
/// that exactly one source was provided before calling this.
private func readOverrideBody(file: String?, stdin: Bool) throws -> String {
    let data: Data
    if let file {
        let path = (file as NSString).expandingTildeInPath
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ValidationError("Could not read override file \(path): \(error.localizedDescription)")
        }
    } else if stdin {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        throw ValidationError("Provide --file <path> or --stdin with the override body.")
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw ValidationError("The override body is not valid UTF-8 text.")
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("The override body is empty.")
    }
    return text
}

/// Writes a mutation report and mirrors its warnings to stderr in text mode.
/// JSON mode keeps them inside the payload so stdout stays machine-readable.
private func writeOverrideReport<T: Encodable>(
    _ report: T,
    warnings: [String],
    text: (T) -> String
) {
    CLIRuntime.current.write(report, text: text)
    for warning in warnings {
        CLIRuntime.current.log(.warn, warning)
    }
}

private func overrideEffectText(_ report: OverrideMutationReport) -> String {
    overrideEffectText(restartRequested: report.restartRequested, restarted: report.restarted)
}

private func overrideEffectText(_ report: OverrideDeleteReport) -> String {
    overrideEffectText(restartRequested: report.restartRequested, restarted: report.restarted)
}

private func overrideEffectText(_ report: OverrideReorderReport) -> String {
    overrideEffectText(restartRequested: report.restartRequested, restarted: report.restarted)
}

private func overrideEffectText(restartRequested: Bool, restarted: Bool) -> String {
    if restarted {
        return "core restarted"
    }
    if restartRequested {
        return "takes effect on next core start (core not running)"
    }
    return "takes effect on next core start"
}
