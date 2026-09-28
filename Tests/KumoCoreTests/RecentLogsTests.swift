import Foundation
import XCTest
@testable import KumoCoreKit

/// Covers the tail-read behavior of `KumoController.recentLogs()`: only the
/// last window of `core.log` is read, the first line of that window is never a
/// truncated fragment, and entry ids are content-derived rather than
/// positional so they survive refreshes.
final class RecentLogsTests: XCTestCase {
    func testSmallFileReturnsEveryLineInOrder() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = try makeController(withLogLines: [
            "2026-09-28 10:00:00 level=info msg=first",
            "2026-09-28 10:00:01 level=error msg=second",
            "2026-09-28 10:00:02 level=debug msg=third"
        ], paths: paths)

        let entries = try controller.recentLogs()

        XCTAssertEqual(entries.map(\.message), [
            "2026-09-28 10:00:00 level=info msg=first",
            "2026-09-28 10:00:01 level=error msg=second",
            "2026-09-28 10:00:02 level=debug msg=third"
        ])
        XCTAssertEqual(entries.map(\.level), ["info", "error", "debug"])
    }

    func testMissingFileReturnsEmptySnapshot() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = KumoController(paths: paths)

        XCTAssertTrue(try controller.recentLogs().isEmpty)
    }

    func testLimitZeroReturnsEmptySnapshot() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = try makeController(withLogLines: ["alpha", "beta"], paths: paths)

        XCTAssertTrue(try controller.recentLogs(limit: 0).isEmpty)
    }

    func testLargeFileReturnsCompleteTailLinesOnly() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        // ~14 bytes per line, so 20k filler lines push the file well past the
        // 256 KB window and force the reader to start mid-file.
        let filler = (1...20_000).map { String(format: "filler-%06d", $0) }
        let tail = (1...5).map { "tail-marker-\($0)" }
        let controller = try makeController(withLogLines: filler + tail, paths: paths)
        XCTAssertGreaterThan(
            try fileSize(at: paths.coreLogFile),
            UInt64(KumoController.recentLogByteWindow),
            "fixture must exceed the tail window for this test to mean anything"
        )

        let entries = try controller.recentLogs(limit: 300)

        XCTAssertEqual(entries.count, 300)
        XCTAssertEqual(
            entries.map(\.message),
            (filler + tail).suffix(300).map { $0 },
            "the tail window is far larger than 300 lines, so the last 300 complete lines are expected"
        )
        for entry in entries {
            XCTAssertNotNil(
                entry.message.range(of: #"^(filler-\d{6}|tail-marker-\d)$"#, options: .regularExpression),
                "partial line returned: \(entry.message)"
            )
        }
    }

    func testIdsStayStableWhenNewLinesAreAppended() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let initial = (1...10).map { String(format: "line-%02d", $0) }
        let controller = try makeController(withLogLines: initial, paths: paths)

        let before = try controller.recentLogs(limit: 5)
        XCTAssertEqual(before.map(\.message), Array(initial.suffix(5)))

        try appendLogLines(["line-11"], to: paths.coreLogFile)
        let after = try controller.recentLogs(limit: 5)

        XCTAssertEqual(after.map(\.message), (initial + ["line-11"]).suffix(5).map { $0 })
        for entry in before.dropFirst() {
            let matching = after.first { $0.message == entry.message }
            XCTAssertEqual(
                matching?.id,
                entry.id,
                "id for \(entry.message) changed across a refresh"
            )
        }
    }

    func testRepeatedReadsReturnIdenticalIds() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = try makeController(withLogLines: ["alpha", "beta", "gamma"], paths: paths)

        XCTAssertEqual(try controller.recentLogs(), try controller.recentLogs())
    }

    func testDuplicateMessagesGetUniqueIds() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let controller = try makeController(
            withLogLines: ["repeated", "repeated", "unique", "repeated"],
            paths: paths
        )

        let entries = try controller.recentLogs()

        XCTAssertEqual(entries.map(\.message), ["repeated", "repeated", "unique", "repeated"])
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "duplicate messages must not collide")
    }

    // MARK: - Helpers

    private func makeController(withLogLines lines: [String], paths: KumoPaths) throws -> KumoController {
        try writeLogLines(lines, to: paths.coreLogFile)
        return KumoController(paths: paths)
    }

    private func writeLogLines(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendLogLines(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
