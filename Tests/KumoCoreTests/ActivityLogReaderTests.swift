import Foundation
import XCTest
@testable import KumoCoreKit

final class ActivityLogReaderTests: XCTestCase {
    func testRecentEntriesMergesCLIFilesAndRuntimeEventsNewestFirst() throws {
        let paths = makePaths()
        let cliDirectory = paths.logsDirectory.appendingPathComponent("cli", isDirectory: true)
        try write(
            "2026-10-05 10:00:00 +0000 info from-invocation\n",
            to: cliDirectory.appendingPathComponent("2026-a-kumo-debug-0.log")
        )
        try write(
            "2026-10-05 10:00:01 +0000 notice from-direct-log\n",
            to: paths.logsDirectory.appendingPathComponent("cli.log")
        )
        try writeRuntimeEvents(
            [RuntimeEventEntry(
                id: "runtime-newest",
                time: Date(timeIntervalSince1970: 2_000_000_000),
                kind: "config.apply",
                message: "from-runtime"
            )],
            to: paths.runtimeEventsFile
        )

        let entries = try ActivityLogReader(paths: paths).recentEntries()

        XCTAssertEqual(entries.map(\.message), ["from-runtime", "from-direct-log", "from-invocation"])
        XCTAssertEqual(entries.map(\.source), [.runtime, .cli, .cli])
        XCTAssertEqual(entries.map(\.category), ["config.apply", "cli", "cli"])
        XCTAssertEqual(entries.map(\.level), ["info", "notice", "info"])
        XCTAssertEqual(try ActivityLogReader(paths: paths).recentEntries(limit: 0), [])
    }

    func testTailReadSkipsPartialLeadingLineAndReturnsNewestEntries() throws {
        let paths = makePaths()
        let messages = (0..<10).map { "entry-\($0)-\(String(repeating: "x", count: 20))" }
        let contents = messages.enumerated().map {
            "2026-10-05 10:00:\(String(format: "%02d", $0.offset)) +0000 info \($0.element)\n"
        }.joined()
        let url = paths.logsDirectory.appendingPathComponent("cli.log")
        try write(contents, to: url)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 130)

        let entries = try ActivityLogReader(paths: paths, maxTailBytes: 130).recentEntries()

        XCTAssertEqual(entries.map(\.message), [messages[9], messages[8]])
        XCTAssertFalse(entries.contains { $0.message.contains("entry-7") })
    }

    func testMissingFilesAndMalformedLinesAreIgnored() throws {
        let paths = makePaths()
        let reader = ActivityLogReader(paths: paths)
        XCTAssertEqual(try reader.recentEntries(), [])

        let cliDirectory = paths.logsDirectory.appendingPathComponent("cli", isDirectory: true)
        try write(
            "malformed\n2026-10-05T10:00:00Z warning valid-iso\nnot-a-date info invalid\n",
            to: cliDirectory.appendingPathComponent("2026-a-kumo-debug-0.log")
        )
        try write(
            "{not-json}\n",
            to: paths.runtimeEventsFile
        )

        let entries = try reader.recentEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "valid-iso")
        XCTAssertEqual(entries[0].level, "warning")
        XCTAssertEqual(entries[0].source, .cli)
    }

    private func makePaths() -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-activity-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return KumoPaths(applicationSupportDirectory: root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func writeRuntimeEvents(_ events: [RuntimeEventEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try events.map { try encoder.encode($0) }.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
