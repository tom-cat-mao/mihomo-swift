import Darwin
import Foundation
import XCTest
@testable import KumoCoreKit

final class AppSupportOwnershipRepairTests: XCTestCase {
    func testRepairTargetsCoverRootAndNonSymlinkedDescendants() throws {
        let root = try temporaryDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try "".write(
            to: root.appendingPathComponent("logs/runtime-events.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let repair = AppSupportOwnershipRepair(applicationSupportDirectory: root, ownerUID: 501, ownerGID: 20)

        XCTAssertEqual(
            relativePaths(in: repair.repairTargets(), root: root),
            ["", "logs", "logs/runtime-events.jsonl", "state.json", "work"]
        )
    }

    /// The repair is a single pass over the app-support tree: it must neither
    /// chown a symlink nor follow one out of the tree.
    func testRepairTargetsSkipSymlinksAndSymlinkedDirectories() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

        let outsideFile = outside.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        let outsideDirectory = outside.appendingPathComponent("outside-directory")
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "nested".write(
            to: outsideDirectory.appendingPathComponent("nested.txt"),
            atomically: true,
            encoding: .utf8
        )

        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("state.json"),
            withDestinationURL: outsideFile
        )
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked-outside"),
            withDestinationURL: outsideDirectory
        )
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("logs/linked-outside"),
            withDestinationURL: outsideDirectory
        )
        try "inside".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let repair = AppSupportOwnershipRepair(applicationSupportDirectory: root, ownerUID: 501, ownerGID: 20)

        XCTAssertEqual(
            relativePaths(in: repair.repairTargets(), root: root),
            ["", "logs", "notes.txt"],
            "symlinked entries and everything behind them must be left untouched"
        )
    }

    /// `geteuid() != 0` means the repair must be an inert no-op: it can neither
    /// chown nor fail, because the daemon and an unprivileged caller share this
    /// type.
    func testRepairIsNoOpWhenNotRoot() throws {
        try XCTSkipIf(geteuid() == 0, "Ownership checks are only meaningful for an unprivileged process.")

        let root = try temporaryDirectory()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let stateFile = root.appendingPathComponent("state.json")
        try "{}".write(to: stateFile, atomically: true, encoding: .utf8)

        let repair = AppSupportOwnershipRepair(applicationSupportDirectory: root, ownerUID: 0, ownerGID: 0)
        let repaired = repair.repair()

        XCTAssertEqual(repaired, 0)
        XCTAssertEqual(ownerID(ofItemAt: stateFile), Int(getuid()))
        XCTAssertEqual(ownerID(ofItemAt: root), Int(getuid()))
    }

    func testAuthorizedUIDResolvesTheUsersPrimaryGID() throws {
        let repair = try XCTUnwrap(
            AppSupportOwnershipRepair(
                applicationSupportDirectory: temporaryDirectory(),
                authorizedUID: getuid()
            )
        )

        XCTAssertEqual(repair.ownerUID, getuid())
        XCTAssertEqual(repair.ownerGID, getgid())

        let unknownUserRepair = AppSupportOwnershipRepair(
            applicationSupportDirectory: try temporaryDirectory(),
            authorizedUID: uid_t.max
        )
        XCTAssertNil(unknownUserRepair, "an unknown uid has no passwd entry and must skip the repair")
    }

    /// Absolute comparison is unreliable under `/var`: the enumerator resolves
    /// the `/private/var` symlink for children while the URL handed to it keeps
    /// the `/var` prefix. Normalize that prefix and assert on paths relative to
    /// the fixture root; the root itself is `""`.
    private func relativePaths(in targets: [URL], root: URL) -> Set<String> {
        let rootPath = canonicalPath(of: root)
        return Set(targets.map { url in
            canonicalPath(of: url)
                .replacingOccurrences(of: rootPath, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        })
    }

    private func canonicalPath(of url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    private func ownerID(ofItemAt url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.ownerAccountID] as? NSNumber)?.intValue
    }

    private func temporaryDirectory() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
