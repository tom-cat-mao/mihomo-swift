import Foundation

public enum ActivityLogSource: String, Codable, Equatable, Sendable, CaseIterable {
    case cli
    case runtime
}

public struct ActivityLogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let source: ActivityLogSource
    public let level: String
    public let category: String
    public let message: String

    public init(
        id: String,
        timestamp: Date,
        source: ActivityLogSource,
        level: String,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct ActivityLogReader: Sendable {
    public let paths: KumoPaths
    private let maxTailBytes: Int
    private var fileManager: FileManager { .default }

    public init(paths: KumoPaths, maxTailBytes: Int = 256 * 1024) {
        self.paths = paths
        self.maxTailBytes = max(0, maxTailBytes)
    }

    public func recentEntries(limit: Int = 200) throws -> [ActivityLogEntry] {
        guard limit > 0 else { return [] }
        var entries = runtimeEntries()
        entries.append(contentsOf: cliEntries())
        entries.sort {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp > $1.timestamp
        }
        return Array(entries.prefix(limit))
    }

    private func runtimeEntries() -> [ActivityLogEntry] {
        guard let lines = try? tailLines(at: paths.runtimeEventsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { line in
            guard let data = line.text.data(using: .utf8),
                  let event = try? decoder.decode(RuntimeEventEntry.self, from: data) else {
                return nil
            }
            return ActivityLogEntry(
                id: "runtime:\(event.id)",
                timestamp: event.time,
                source: .runtime,
                level: runtimeLevel(kind: event.kind),
                category: event.kind,
                message: event.message
            )
        }
    }

    private func cliEntries() -> [ActivityLogEntry] {
        let directory = paths.logsDirectory.appendingPathComponent("cli", isDirectory: true)
        let files = ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter {
                let name = $0.lastPathComponent
                return name.contains("-kumo-debug-") && name.hasSuffix(".log")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(20)

        var entries = files.flatMap { cliEntries(at: $0) }
        entries.append(contentsOf: cliEntries(at: paths.logsDirectory.appendingPathComponent("cli.log")))
        return entries
    }

    private func cliEntries(at url: URL) -> [ActivityLogEntry] {
        guard let lines = try? tailLines(at: url) else { return [] }
        return lines.compactMap { line in
            guard let parsed = parseCLILine(line.text) else { return nil }
            return ActivityLogEntry(
                id: "cli:\(url.path):\(line.offset)",
                timestamp: parsed.timestamp,
                source: .cli,
                level: parsed.level,
                category: "cli",
                message: parsed.message
            )
        }
    }

    private func parseCLILine(_ line: String) -> (timestamp: Date, level: String, message: String)? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 3 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        if tokens.count >= 4 {
            let standardTimestamp = tokens[0...2].joined(separator: " ")
            if let timestamp = formatter.date(from: standardTimestamp) {
                return (
                    timestamp: timestamp,
                    level: String(tokens[3]),
                    message: tokens.dropFirst(4).joined(separator: " ")
                )
            }
        }

        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso8601.date(from: String(tokens[0])) ?? ISO8601DateFormatter().date(from: String(tokens[0]))
        guard let timestamp else { return nil }
        return (
            timestamp: timestamp,
            level: String(tokens[1]),
            message: tokens.dropFirst(2).joined(separator: " ")
        )
    }

    private func runtimeLevel(kind: String) -> String {
        let kind = kind.lowercased()
        if kind.contains("error") || kind.contains("fail") || kind.contains("fatal") ||
            kind.contains("unexpected") || kind.contains("crash") {
            return "error"
        }
        if kind.contains("warn") || kind.contains("stale") {
            return "warning"
        }
        return "info"
    }

    private func tailLines(at url: URL) throws -> [(offset: UInt64, text: String)] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let window = UInt64(maxTailBytes)
        let readSize = min(fileSize, window)
        let startOffset = fileSize - readSize
        try handle.seek(toOffset: startOffset)
        let bytes = [UInt8](try handle.readToEnd() ?? Data())
        let startedMidFile = fileSize > window
        var lines: [(offset: UInt64, text: String)] = []
        var lineStart = 0
        var lineNumber = 0

        func appendLine(end: Int) {
            defer { lineNumber += 1 }
            guard !(startedMidFile && lineNumber == 0), end > lineStart else { return }
            let text = String(decoding: bytes[lineStart..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lines.append((offset: startOffset + UInt64(lineStart), text: text))
        }

        for index in bytes.indices where bytes[index] == 0x0A {
            appendLine(end: index)
            lineStart = index + 1
        }
        if lineStart < bytes.count {
            appendLine(end: bytes.count)
        }
        return lines
    }
}
