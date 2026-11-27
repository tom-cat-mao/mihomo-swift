import Foundation

public struct ConfigurationRollbackSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let source: String?
    public let summary: String?

    public init(id: String, createdAt: Date, source: String? = nil, summary: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.summary = summary
    }
}

/// Durable, bounded pre-apply states. A point is first written as a hidden
/// pending file and becomes visible to rollback only after the apply succeeds.
struct ConfigurationRollbackStore: Sendable {
    struct Point: Codable, Sendable {
        var id: String
        var createdAt: Date
        var profiles: ProfileRepository.TransactionSnapshot
        var overrides: OverrideRepository.TransactionSnapshot
        var status: CoreStatus
        var runtimeConfiguration: Data?
        var source: String? = nil
        var summary: String? = nil
    }

    struct Staged: Sendable {
        var point: Point
        var pendingURL: URL
    }

    private let directory: URL
    private let limit: Int
    private var fileManager: FileManager { .default }

    init(paths: KumoPaths, limit: Int = 10) {
        self.directory = paths.configurationRollbacksDirectory
        self.limit = max(1, limit)
    }

    func stage(
        profiles: ProfileRepository.TransactionSnapshot,
        overrides: OverrideRepository.TransactionSnapshot,
        status: CoreStatus,
        runtimeConfiguration: Data?,
        source: String? = nil,
        summary: String? = nil
    ) throws -> Staged {
        try prepareDirectory()
        let point = Point(
            id: UUID().uuidString,
            createdAt: Date(),
            profiles: profiles,
            overrides: overrides,
            status: status,
            runtimeConfiguration: runtimeConfiguration,
            source: source,
            summary: summary
        )
        let pendingURL = directory.appendingPathComponent(".\(point.id).pending")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(point).write(to: pendingURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
        return Staged(point: point, pendingURL: pendingURL)
    }

    /// Makes room and computes the result before atomically promoting the point.
    /// No throwing operation follows the move, so a reported commit failure can
    /// never leave behind a committed point.
    @discardableResult
    func commit(_ staged: Staged) throws -> Int {
        let previousCount = try committedURLs().count
        let resultingCount = min(previousCount + 1, limit)
        try pruneForIncomingPoint()
        try fileManager.moveItem(at: staged.pendingURL, to: fileURL(id: staged.point.id))
        return resultingCount
    }

    func discard(_ staged: Staged) {
        try? fileManager.removeItem(at: staged.pendingURL)
    }

    func latest() throws -> Point? {
        try committedPoints().last
    }

    func count() throws -> Int {
        try committedURLs().count
    }

    func summaries() throws -> [ConfigurationRollbackSummary] {
        try committedPoints().reversed().map {
            ConfigurationRollbackSummary(
                id: $0.id,
                createdAt: $0.createdAt,
                source: $0.source,
                summary: $0.summary
            )
        }
    }

    func consume(id: String) throws {
        let url = fileURL(id: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func fileURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func committedURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    private func committedPoints() throws -> [Point] {
        let decoder = JSONDecoder()
        return try committedURLs()
            .map { try decoder.decode(Point.self, from: Data(contentsOf: $0)) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id < $1.id }
                return $0.createdAt < $1.createdAt
            }
    }

    private func pruneForIncomingPoint() throws {
        let points = try committedPoints()
        guard points.count >= limit else { return }
        for point in points.prefix(points.count - limit + 1) {
            try fileManager.removeItem(at: fileURL(id: point.id))
        }
    }
}
