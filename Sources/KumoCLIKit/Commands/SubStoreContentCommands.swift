import ArgumentParser
import Foundation
import KumoCoreKit

// MARK: - Entry kinds

/// Entry kinds accepted by `kumo substore content` / `preview` and used by
/// the name-resolution helpers. Omitted, the resolver probes subscriptions,
/// then collections, then files.
enum SubStoreContentKind: String, ExpressibleByArgument, CaseIterable {
    case subscription
    case collection
    case file
}

extension KumoCommand.Substore {
    // MARK: - Listings

    struct Subscriptions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Sub-Store subscriptions.")
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let entries = try await SubStoreCommandSupport.subscriptions(
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(entries) { entries in
                entries.isEmpty
                    ? "no Sub-Store subscriptions"
                    : entries.map(SubStoreCommandSupport.entryLine).joined(separator: "\n")
            }
        }
    }

    struct Collections: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Sub-Store collections.")
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let entries = try await SubStoreCommandSupport.collections(
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(entries) { entries in
                entries.isEmpty
                    ? "no Sub-Store collections"
                    : entries.map(SubStoreCommandSupport.entryLine).joined(separator: "\n")
            }
        }
    }

    struct Files: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Sub-Store files.")
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let entries = try await SubStoreCommandSupport.files(
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(entries) { entries in
                entries.isEmpty
                    ? "no Sub-Store files"
                    : entries.map(SubStoreCommandSupport.fileLine).joined(separator: "\n")
            }
        }
    }

    struct Modules: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List Sub-Store modules.")
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let entries = try await SubStoreCommandSupport.modules(
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(entries) { entries in
                entries.isEmpty
                    ? "no Sub-Store modules"
                    : entries.map(SubStoreCommandSupport.moduleLine).joined(separator: "\n")
            }
        }
    }

    // MARK: - Content

    struct Content: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one Sub-Store entry's detail.",
            discussion: "Without --kind the name is resolved against subscriptions, then collections, then files. Entry kinds other than subscription/collection/file are not exposed."
        )

        @Argument(help: "Sub-Store entry name (or display name).")
        var name: String
        @Option(name: .long, help: "Entry kind: subscription, collection, or file.")
        var kind: SubStoreContentKind?
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let payload = try await SubStoreCommandSupport.content(
                name: name,
                kind: kind,
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(payload, text: SubStoreCommandSupport.contentText)
        }
    }

    struct Preview: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preview a Sub-Store entry's parsed nodes.",
            discussion: "Previews the backend's JSON target: text mode prints the node list, --json prints the original/processed node arrays. Preview output is never rendered Clash YAML."
        )

        @Argument(help: "Sub-Store entry name (or display name).")
        var name: String
        @Option(name: .long, help: "Entry kind: subscription, collection, or file.")
        var kind: SubStoreContentKind?
        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let payload = try await SubStoreCommandSupport.preview(
                name: name,
                kind: kind,
                client: CLIRuntime.current.controller.subStoreClient()
            )
            CLIRuntime.current.write(payload, text: SubStoreCommandSupport.previewText)
        }
    }

    // MARK: - Import

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import a Sub-Store subscription or collection as a Kumo profile.",
            discussion: "A bare name resolves against subscriptions first, then collections (canonical name first, then display name). A /download path or a URL with a scheme is used unchanged. Files and modules are not Clash profiles and cannot be imported."
        )

        @Argument(help: "Sub-Store name, /download path, or URL.")
        var nameOrPath: String
        @Option(name: .long, help: "Profile name to store in Kumo (defaults to the entry display name or the path's last component).")
        var name: String?
        @Flag(name: .long, help: "Download through the local Mihomo proxy; requires a running core.")
        var useProxy = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if let name, name.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ValidationError("The profile name must not be empty.")
            }
        }

        mutating func run() async throws {
            try options.install()
            let report = try await SubStoreCommandSupport.importProfile(
                controller: CLIRuntime.current.controller,
                nameOrPath: nameOrPath,
                name: name,
                useProxy: useProxy
            )
            CLIRuntime.current.write(report) { report in
                "imported Sub-Store \(report.kind) \(report.input) as profile \(report.profile.id) (\(report.profile.name))"
            }
        }
    }

    // MARK: - Backend settings and logs

    struct Settings: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the Sub-Store backend URL, mode, and settings.",
            discussion: "The backend URL and mode always come from local state. The backend's own settings are fetched when it answers; otherwise settingsError explains why and the command still succeeds."
        )

        @OptionGroup var options: CLIOptions

        mutating func run() async throws {
            try options.install()
            let report = try await SubStoreCommandSupport.settingsReport(controller: CLIRuntime.current.controller)
            CLIRuntime.current.write(report, text: SubStoreCommandSupport.settingsText)
            if let error = report.settingsError {
                CLIRuntime.current.log(.warn, "backend settings unavailable: \(error)")
            }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show recent Sub-Store backend log entries.",
            discussion: "Reads the backend's log buffer; when the backend cannot be reached it falls back to the supervisor-captured substore.log and reports source=file."
        )

        @Option(name: .long, help: "Maximum number of log entries to print.")
        var limit = 200
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if limit < 1 {
                throw ValidationError("--limit must be at least 1.")
            }
        }

        mutating func run() async throws {
            try options.install()
            let payload = try await SubStoreCommandSupport.logs(controller: CLIRuntime.current.controller, limit: limit)
            CLIRuntime.current.write(payload) { payload in
                payload.entries.isEmpty
                    ? "no Sub-Store log entries"
                    : payload.entries.map(SubStoreCommandSupport.logLine).joined(separator: "\n")
            }
            if let error = payload.backendError {
                CLIRuntime.current.log(.warn, "backend log unavailable (\(error)); showing \(payload.path ?? "substore.log")")
            }
        }
    }
}

// MARK: - Import resolution

enum SubStoreImportKind: String, Equatable {
    case subscription
    case collection
    case path
}

/// A Sub-Store download target resolved from a CLI name or path.
struct SubStoreImportTarget: Equatable {
    var input: String
    /// Display name of the matched entry; `nil` for explicit paths so Kumo
    /// derives the profile name from the path itself.
    var profileName: String?
    var path: String
    var kind: SubStoreImportKind
}

enum SubStoreEntrySelection: Equatable {
    case subscription(SubStoreSubscription)
    case collection(SubStoreCollection)
    case file(SubStoreFile)

    var kind: SubStoreContentKind {
        switch self {
        case .subscription: .subscription
        case .collection: .collection
        case .file: .file
        }
    }
}

// MARK: - Support

/// Execution helpers shared by the `kumo substore` content subcommands.
///
/// They take a `KumoController`/`SubStoreClient` directly instead of reading
/// `CLIRuntime.current`, so tests can exercise resolution and payload mapping
/// against a stubbed backend. All operations are read-only except
/// `importProfile`, which stores one Kumo profile.
enum SubStoreCommandSupport {
    /// The GUI previews through the backend's JSON target; the CLI mirrors it
    /// so preview output stays a node array instead of rendered YAML.
    static let previewTarget = "JSON"

    // MARK: Listings

    /// Same mapping as `KumoController.subStoreEntries(kind:)`, kept here so
    /// the listing commands can be exercised against a stubbed client.
    static func subscriptions(client: SubStoreClient) async throws -> [SubStoreEntry] {
        try await client.subscriptions().map {
            SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: $0.tag ?? [], kind: .subscription)
        }
    }

    static func collections(client: SubStoreClient) async throws -> [SubStoreEntry] {
        try await client.collections().map {
            SubStoreEntry(name: $0.name, displayName: $0.displayName, icon: $0.icon, tags: [], kind: .collection)
        }
    }

    static func files(client: SubStoreClient) async throws -> [SubStoreFileListEntry] {
        try await client.files().map { file in
            SubStoreFileListEntry(
                name: file.name,
                displayName: file.displayName,
                type: file.type,
                source: file.source,
                url: file.url
            )
        }
    }

    static func modules(client: SubStoreClient) async throws -> [SubStoreModuleListEntry] {
        try await client.modules().map { module in
            SubStoreModuleListEntry(
                name: module.name,
                description: module.description,
                icon: module.icon
            )
        }
    }

    // MARK: Content

    static func content(name: String, kind: SubStoreContentKind?, client: SubStoreClient) async throws -> SubStoreContentPayload {
        let selection = try await selectEntry(name: name, kind: kind, client: client)
        switch selection {
        case .subscription(let subscription):
            return SubStoreContentPayload(kind: selection.kind.rawValue, name: subscription.name, entry: try jsonValue(subscription))
        case .collection(let collection):
            return SubStoreContentPayload(kind: selection.kind.rawValue, name: collection.name, entry: try jsonValue(collection))
        case .file(let file):
            return SubStoreContentPayload(kind: selection.kind.rawValue, name: file.name, entry: try jsonValue(file))
        }
    }

    static func preview(name: String, kind: SubStoreContentKind?, client: SubStoreClient) async throws -> SubStorePreviewPayload {
        let selection = try await selectEntry(name: name, kind: kind, client: client)
        switch selection {
        case .subscription(let subscription):
            return previewPayload(
                kind: .subscription,
                name: subscription.name,
                result: try await client.previewSubscription(subscription, target: previewTarget)
            )
        case .collection(let collection):
            return previewPayload(
                kind: .collection,
                name: collection.name,
                result: try await client.previewCollection(collection, target: previewTarget)
            )
        case .file(let file):
            return previewPayload(kind: .file, name: file.name, result: try await client.previewFile(file))
        }
    }

    // MARK: Import

    static func importProfile(
        controller: KumoController,
        nameOrPath: String,
        name: String?,
        useProxy: Bool
    ) async throws -> SubStoreImportReport {
        let target: SubStoreImportTarget
        if let explicit = explicitImportTarget(nameOrPath) {
            target = explicit
        } else {
            let client = try controller.subStoreClient()
            async let subscriptions = controller.subStoreEntries(kind: .subscription)
            async let collections = controller.subStoreEntries(kind: .collection)
            async let files = client.files()
            target = try resolveImportTarget(
                nameOrPath,
                subscriptions: try await subscriptions,
                collections: try await collections,
                files: try await files
            )
        }

        let profile = try await controller.importSubStoreProfile(
            path: target.path,
            name: name ?? target.profileName,
            useProxy: useProxy
        )
        return SubStoreImportReport(
            input: target.input,
            kind: target.kind.rawValue,
            path: target.path,
            useProxy: useProxy,
            profile: profile
        )
    }

    // MARK: Backend settings and logs

    static func settingsReport(controller: KumoController) async throws -> SubStoreSettingsReport {
        let runtime = try await controller.subStoreRuntimeStatus()
        var settings: SubStoreSettings?
        var settingsError: String?
        if runtime.backendURL != nil {
            do {
                settings = try await controller.subStoreClient().settings()
            } catch {
                settingsError = describe(error)
            }
        } else {
            settingsError = "Sub-Store backend is not configured."
        }
        let configuration = runtime.configuration
        return SubStoreSettingsReport(
            backendURL: runtime.backendURL?.absoluteString,
            backendMode: configuration.usesCustomBackend ? "custom" : "bundled",
            customBackendURL: configuration.customBackendURL?.absoluteString,
            isEnabled: configuration.isEnabled,
            isBackendRunning: runtime.isBackendRunning,
            host: configuration.host,
            port: configuration.backendPort,
            allowsLAN: configuration.allowsLAN,
            usesProxy: configuration.usesProxy,
            syncCron: configuration.syncCron,
            downloadCron: configuration.downloadCron,
            uploadCron: configuration.uploadCron,
            resourceVersion: runtime.resourceVersion,
            settings: settings,
            settingsError: settingsError
        )
    }

    static func logs(controller: KumoController, limit: Int) async throws -> SubStoreLogPayload {
        let fileURL = controller.paths.subStoreLogFile
        let client: SubStoreClient
        do {
            client = try controller.subStoreClient()
        } catch {
            return try fileLogPayload(fileURL: fileURL, backendError: describe(error), limit: limit, underlying: error)
        }
        return try await logs(client: client, logFileURL: fileURL, limit: limit)
    }

    /// Reads the backend log buffer and falls back to `logFileURL` when the
    /// backend cannot answer. Split out from the controller entry point so
    /// tests can stub the backend with a `URLSession` protocol class.
    static func logs(client: SubStoreClient, logFileURL: URL, limit: Int) async throws -> SubStoreLogPayload {
        do {
            let entries = try await client.logs(limit: limit)
            return SubStoreLogPayload(source: "backend", path: nil, backendError: nil, entries: entries)
        } catch {
            return try fileLogPayload(fileURL: logFileURL, backendError: describe(error), limit: limit, underlying: error)
        }
    }

    // MARK: Resolution

    /// Resolves a CLI name or path to a Sub-Store download path. Mirrors the
    /// GUI/controller path shapes (`SubStoreEntry.downloadPath`): subscriptions
    /// live at `/download/<name>`, collections at `/download/collection/<name>`.
    /// Files and modules are not importable as profiles, so a file match fails
    /// with a pointer to `substore content --kind file`.
    static func resolveImportTarget(
        _ nameOrPath: String,
        subscriptions: [SubStoreEntry],
        collections: [SubStoreEntry],
        files: [SubStoreFile]
    ) throws -> SubStoreImportTarget {
        let query = try normalizedQuery(nameOrPath)
        if isExplicitSubStorePath(query) {
            return SubStoreImportTarget(input: nameOrPath, profileName: nil, path: query, kind: .path)
        }
        if let subscription = try uniqueMatch(query, in: subscriptions, name: { $0.name }, displayName: { $0.displayName }) {
            return SubStoreImportTarget(
                input: nameOrPath,
                profileName: subscription.resolvedDisplayName,
                path: subscription.downloadPath,
                kind: .subscription
            )
        }
        if let collection = try uniqueMatch(query, in: collections, name: { $0.name }, displayName: { $0.displayName }) {
            return SubStoreImportTarget(
                input: nameOrPath,
                profileName: collection.resolvedDisplayName,
                path: collection.downloadPath,
                kind: .collection
            )
        }
        if try uniqueMatch(query, in: files, name: { $0.name }, displayName: { $0.displayName }) != nil {
            throw ValidationError(
                "`\(query)` is a Sub-Store file, not a subscription or collection. Files are not Clash profiles and cannot be imported; inspect it with `kumo substore content \(query) --kind file` or pass an explicit /download path."
            )
        }
        throw ValidationError(
            "No Sub-Store subscription or collection named `\(query)`. Run `kumo substore subscriptions` or `kumo substore collections` to list available names."
        )
    }

    /// An explicit `/download` path or a URL with a scheme skips name lookup.
    /// Mirrors `KumoController.subStoreProfileDownloadURL`, which treats any
    /// string with a URL scheme as an absolute URL.
    static func explicitImportTarget(_ nameOrPath: String) -> SubStoreImportTarget? {
        let trimmed = nameOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isExplicitSubStorePath(trimmed) else { return nil }
        return SubStoreImportTarget(input: nameOrPath, profileName: nil, path: trimmed, kind: .path)
    }

    static func isExplicitSubStorePath(_ value: String) -> Bool {
        value.hasPrefix("/") || URL(string: value)?.scheme != nil
    }

    static func selectEntry(
        name: String,
        kind: SubStoreContentKind?,
        client: SubStoreClient
    ) async throws -> SubStoreEntrySelection {
        let query = try normalizedQuery(name)
        switch kind {
        case .subscription:
            return .subscription(try requireMatch(
                query,
                kind: .subscription,
                in: try await client.subscriptions(),
                name: { $0.name },
                displayName: { $0.displayName }
            ))
        case .collection:
            return .collection(try requireMatch(
                query,
                kind: .collection,
                in: try await client.collections(),
                name: { $0.name },
                displayName: { $0.displayName }
            ))
        case .file:
            return .file(try requireMatch(
                query,
                kind: .file,
                in: try await client.files(),
                name: { $0.name },
                displayName: { $0.displayName }
            ))
        case nil:
            if let subscription = try uniqueMatch(query, in: try await client.subscriptions(), name: { $0.name }, displayName: { $0.displayName }) {
                return .subscription(subscription)
            }
            if let collection = try uniqueMatch(query, in: try await client.collections(), name: { $0.name }, displayName: { $0.displayName }) {
                return .collection(collection)
            }
            if let file = try uniqueMatch(query, in: try await client.files(), name: { $0.name }, displayName: { $0.displayName }) {
                return .file(file)
            }
            throw ValidationError(
                "No Sub-Store subscription, collection, or file named `\(query)`. Run `kumo substore subscriptions`, `kumo substore collections`, or `kumo substore files` to list available names."
            )
        }
    }

    /// Matches the canonical name first, then the display name. A display
    /// name that matches more than one entry is ambiguous and fails.
    static func uniqueMatch<T>(
        _ query: String,
        in items: [T],
        name: (T) -> String,
        displayName: (T) -> String?
    ) throws -> T? {
        if let exact = items.first(where: { name($0) == query }) {
            return exact
        }
        let displayMatches = items.filter { displayName($0) == query }
        if displayMatches.count > 1 {
            throw ValidationError("`\(query)` matches \(displayMatches.count) Sub-Store entries by display name; use the canonical name instead.")
        }
        return displayMatches.first
    }

    // MARK: Formatting

    static func entryLine(_ entry: SubStoreEntry) -> String {
        var parts = [entry.name]
        if let displayName = entry.displayName, !displayName.isEmpty {
            parts.append(displayName)
        }
        parts.append(contentsOf: entry.tags.map { "#\($0)" })
        return parts.joined(separator: " ")
    }

    static func fileLine(_ entry: SubStoreFileListEntry) -> String {
        var parts = [entry.name]
        if let displayName = entry.displayName, !displayName.isEmpty {
            parts.append(displayName)
        }
        if let type = entry.type, !type.isEmpty {
            parts.append(type)
        }
        if let source = entry.source, !source.isEmpty {
            parts.append(source)
        }
        return parts.joined(separator: " ")
    }

    static func moduleLine(_ entry: SubStoreModuleListEntry) -> String {
        var parts = [entry.name]
        if let description = entry.description, !description.isEmpty {
            parts.append(description)
        }
        return parts.joined(separator: " ")
    }

    static func contentText(_ payload: SubStoreContentPayload) -> String {
        guard let data = try? JSONEncoder.subStore.encode(payload.entry) else { return payload.name }
        switch SubStoreContentKind(rawValue: payload.kind) {
        case .subscription:
            guard let subscription = try? JSONDecoder.subStore.decode(SubStoreSubscription.self, from: data) else {
                return payload.name
            }
            var parts = [subscription.name]
            if let displayName = subscription.displayName, !displayName.isEmpty {
                parts.append(displayName)
            }
            parts.append("source=\(subscription.source ?? "-")")
            if let url = subscription.url, !url.isEmpty {
                parts.append(url)
            }
            parts.append("tags=\(subscription.tag?.count ?? 0)")
            parts.append("process=\(subscription.process?.count ?? 0)")
            return parts.joined(separator: " ")
        case .collection:
            guard let collection = try? JSONDecoder.subStore.decode(SubStoreCollection.self, from: data) else {
                return payload.name
            }
            var parts = [collection.name]
            if let displayName = collection.displayName, !displayName.isEmpty {
                parts.append(displayName)
            }
            parts.append("subscriptions=\(collection.subscriptions.count)")
            parts.append("process=\(collection.process?.count ?? 0)")
            return parts.joined(separator: " ")
        case .file:
            guard let file = try? JSONDecoder.subStore.decode(SubStoreFile.self, from: data) else {
                return payload.name
            }
            var parts = [file.name]
            if let displayName = file.displayName, !displayName.isEmpty {
                parts.append(displayName)
            }
            if let type = file.type, !type.isEmpty {
                parts.append("type=\(type)")
            }
            if let source = file.source, !source.isEmpty {
                parts.append("source=\(source)")
            }
            if let url = file.url, !url.isEmpty {
                parts.append(url)
            }
            return parts.joined(separator: " ")
        case nil:
            return payload.name
        }
    }

    static func previewText(_ payload: SubStorePreviewPayload) -> String {
        let nodes = payload.processed.isEmpty ? payload.original : payload.processed
        var lines = [
            "\(payload.kind) \(payload.name): original=\(payload.originalCount) processed=\(payload.processedCount)"
        ]
        lines.append(contentsOf: nodes.prefix(20).compactMap { nodeName($0) })
        if nodes.count > 20 {
            lines.append("... and \(nodes.count - 20) more")
        }
        return lines.joined(separator: "\n")
    }

    static func logLine(_ entry: SubStoreLogEntry) -> String {
        var parts: [String] = []
        if let time = entry.time {
            parts.append(Date(timeIntervalSince1970: TimeInterval(time)).formatted(.iso8601))
        }
        if let level = entry.level, !level.isEmpty {
            parts.append(level.uppercased())
        }
        parts.append(entry.message)
        return parts.joined(separator: " ")
    }

    static func settingsText(_ report: SubStoreSettingsReport) -> String {
        var lines = [
            [
                "backend=\(report.backendURL ?? "-")",
                "mode=\(report.backendMode)",
                "enabled=\(report.isEnabled)",
                "running=\(report.isBackendRunning)",
                "host=\(report.host)",
                "port=\(report.port.map(String.init) ?? "-")",
                "lan=\(report.allowsLAN)",
                "proxy=\(report.usesProxy)"
            ].joined(separator: " ")
        ]
        if let settings = report.settings,
           let data = try? JSONEncoder.subStore.encode(settings.raw),
           let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Internals

    private static func previewPayload(kind: SubStoreContentKind, name: String, result: SubStorePreviewResult) -> SubStorePreviewPayload {
        SubStorePreviewPayload(
            kind: kind.rawValue,
            name: name,
            originalCount: result.original.count,
            processedCount: result.processed.count,
            original: result.original,
            processed: result.processed
        )
    }

    private static func requireMatch<T>(
        _ query: String,
        kind: SubStoreContentKind,
        in items: [T],
        name: (T) -> String,
        displayName: (T) -> String?
    ) throws -> T {
        guard let match = try uniqueMatch(query, in: items, name: name, displayName: displayName) else {
            throw missingEntryError(query, kind: kind)
        }
        return match
    }

    private static func missingEntryError(_ query: String, kind: SubStoreContentKind) -> ValidationError {
        let listCommand = "kumo substore \(kind.rawValue)s"
        return ValidationError("No Sub-Store \(kind.rawValue) named `\(query)`. Run `\(listCommand)` to list available names.")
    }

    private static func normalizedQuery(_ value: String) throws -> String {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ValidationError("Provide a Sub-Store name.")
        }
        return query
    }

    private static func nodeName(_ value: JSONValue) -> String? {
        value.objectValue?["name"]?.stringValue
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.subStore.encode(value)
        return try JSONDecoder.subStore.decode(JSONValue.self, from: data)
    }

    private static func tailLogEntries(_ text: String, limit: Int) -> [SubStoreLogEntry] {
        text.split(whereSeparator: \.isNewline)
            .suffix(limit)
            .map { SubStoreLogEntry(message: String($0)) }
    }

    /// The sidecar writes its console output to substore.log, so the file
    /// still answers when the backend is down or its log payload does not
    /// match the typed client.
    private static func fileLogPayload(
        fileURL: URL,
        backendError: String,
        limit: Int,
        underlying: Error
    ) throws -> SubStoreLogPayload {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw underlying
        }
        return SubStoreLogPayload(
            source: "file",
            path: fileURL.path,
            backendError: backendError,
            entries: tailLogEntries(text, limit: limit)
        )
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
