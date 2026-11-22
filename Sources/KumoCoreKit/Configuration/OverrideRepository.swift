import Foundation

public struct OverrideRepository: Sendable {
    private let paths: KumoPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: KumoPaths = KumoPaths()) {
        self.paths = paths
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func listOverrides() throws -> [OverrideItem] {
        try loadItems()
    }

    public func content(id: String) throws -> String {
        guard let item = try loadItems().first(where: { $0.id == id }) else {
            throw KumoError.invalidArguments("Override not found.")
        }
        return try String(contentsOf: fileURL(for: item), encoding: .utf8)
    }

    @discardableResult
    public func addLocalOverride(name: String, format: OverrideFormat, content: String, isGlobal: Bool = false) throws -> OverrideItem {
        try prepare()
        let item = OverrideItem(name: name, kind: .local, format: format, isGlobal: isGlobal)
        try content.data(using: .utf8)?.write(to: fileURL(for: item), options: .atomic)
        var items = try loadItems()
        items.append(item)
        try saveItems(items)
        return item
    }

    @discardableResult
    public func addRemoteOverride(url: URL, name: String? = nil, format: OverrideFormat = .yaml, fingerprint: String? = nil, isGlobal: Bool = false) async throws -> OverrideItem {
        try prepare()
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw KumoError.invalidArguments("Remote override is not valid UTF-8 text.")
        }
        let item = OverrideItem(
            name: name ?? url.deletingPathExtension().lastPathComponent,
            kind: .remote,
            format: format,
            isGlobal: isGlobal,
            remoteURL: url,
            fingerprint: fingerprint
        )
        try content.data(using: .utf8)?.write(to: fileURL(for: item), options: .atomic)
        var items = try loadItems()
        items.append(item)
        try saveItems(items)
        return item
    }

    public func updateOverride(_ item: OverrideItem, content: String? = nil) throws {
        var items = try loadItems()
        guard let index = items.firstIndex(where: { $0.id == item.id }) else {
            throw KumoError.invalidArguments("Override not found.")
        }
        var updatedItem = item
        updatedItem.updatedAt = Date()
        items[index] = updatedItem
        if let content {
            try content.data(using: .utf8)?.write(to: fileURL(for: updatedItem), options: .atomic)
        }
        try saveItems(items)
    }

    public func deleteOverride(id: String) throws {
        var items = try loadItems()
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }
        items.removeAll { $0.id == id }
        try saveItems(items)
        try? FileManager.default.removeItem(at: fileURL(for: item))
    }

    public func reorderOverrides(ids: [String]) throws {
        let items = try loadItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        let remainder = items.filter { !ids.contains($0.id) }
        try saveItems(ordered + remainder)
    }

    public func activeYAMLs() throws -> [String] {
        try activeOverrides()
            .filter { $0.format == .yaml }
            .map(\.content)
    }

    public func activeOverrides() throws -> [RuntimeOverride] {
        try loadItems().compactMap { item in
            guard let content = try? String(contentsOf: fileURL(for: item), encoding: .utf8) else {
                return nil
            }
            return RuntimeOverride(name: item.name, format: item.format, content: content)
        }
    }

    struct TransactionSnapshot: Codable, Sendable {
        let metadata: Data?
        let files: [String: Data]
    }

    func transactionSnapshot() throws -> TransactionSnapshot {
        let metadata = try? Data(contentsOf: paths.overridesMetadataFile)
        var files: [String: Data] = [:]
        if FileManager.default.fileExists(atPath: paths.overrideFilesDirectory.path) {
            let urls = try FileManager.default.contentsOfDirectory(
                at: paths.overrideFilesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files[url.lastPathComponent] = try Data(contentsOf: url)
            }
        }
        return TransactionSnapshot(metadata: metadata, files: files)
    }

    func restoreTransactionSnapshot(_ snapshot: TransactionSnapshot) throws {
        try FileManager.default.createDirectory(at: paths.overridesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.overrideFilesDirectory, withIntermediateDirectories: true)
        let existing = try FileManager.default.contentsOfDirectory(
            at: paths.overrideFilesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in existing where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try FileManager.default.removeItem(at: url)
        }
        for (name, data) in snapshot.files {
            try data.write(to: paths.overrideFilesDirectory.appendingPathComponent(name), options: .atomic)
        }
        if let metadata = snapshot.metadata {
            try metadata.write(to: paths.overridesMetadataFile, options: .atomic)
        } else if FileManager.default.fileExists(atPath: paths.overridesMetadataFile.path) {
            try FileManager.default.removeItem(at: paths.overridesMetadataFile)
        }
    }

    private func loadItems() throws -> [OverrideItem] {
        guard FileManager.default.fileExists(atPath: paths.overridesMetadataFile.path) else {
            return []
        }
        let data = try Data(contentsOf: paths.overridesMetadataFile)
        return try decoder.decode([OverrideItem].self, from: data)
    }

    private func saveItems(_ items: [OverrideItem]) throws {
        try prepare()
        let data = try encoder.encode(items)
        try data.write(to: paths.overridesMetadataFile, options: .atomic)
    }

    private func fileURL(for item: OverrideItem) -> URL {
        let fileExtension = item.format == .yaml ? "yaml" : "js"
        return paths.overrideFilesDirectory.appendingPathComponent(item.id).appendingPathExtension(fileExtension)
    }

    private func prepare() throws {
        try paths.prepare()
    }
}
