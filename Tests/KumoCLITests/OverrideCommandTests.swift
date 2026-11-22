import ArgumentParser
import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class OverrideCommandTests: XCTestCase {
    // MARK: - Hermetic fixtures

    /// Temp app-support root plus temp LaunchAgents dir so the tier probes
    /// never look at (or near) real user state.
    private func makeTemporaryPaths() throws -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kumo-override-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return KumoPaths(
            applicationSupportDirectory: root,
            launchAgentsDirectory: root.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    private func makeController() throws -> KumoController {
        KumoController(paths: try makeTemporaryPaths())
    }

    private func addOverride(
        _ controller: KumoController,
        name: String,
        content: String = "dns:\n  enable: true\n",
        format: OverrideFormat = .yaml,
        isGlobal: Bool = false
    ) throws -> OverrideItem {
        try controller.addLocalOverride(name: name, format: format, content: content, isGlobal: isGlobal)
    }

    // MARK: - Parsing

    func testOverrideCommandsParse() {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "list", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "content", "abc", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "add", "--name", "dns-fix", "--file", "/tmp/dns.yaml", "--json"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "add", "--name", "dns-fix", "--stdin"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot([
            "override", "add", "--name", "js-fix", "--stdin", "--format", "js", "--global", "--restart"
        ]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot([
            "override", "add", "--url", "https://example.com/override.yaml", "--name", "remote", "--format", "yaml"
        ]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "update", "abc", "--stdin", "--restart"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "delete", "abc", "--dry-run"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["override", "reorder", "--ids", "a,b,c", "--restart"]))
    }

    func testOverrideCommandsRejectBadArguments() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--name", "x"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--name", "x", "--file", "/tmp/a.yaml", "--stdin"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--url", "https://example.com/o.yaml", "--file", "/tmp/a.yaml"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--url", "https://example.com/o.yaml", "--dry-run"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--url", "ftp://example.com/o.yaml"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--name", "x", "--stdin", "--dry-run", "--restart"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "add", "--name", "x", "--stdin", "--format", "javascript"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "update", "abc"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "delete", "abc", "--dry-run", "--restart"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["override", "reorder"]))
    }

    // MARK: - Happy paths on hermetic app support

    func testAddListContentCycle() async throws {
        let paths = try makeTemporaryPaths()
        let controller = KumoController(paths: paths)

        let added = try await OverrideCommandSupport.addLocal(
            controller: controller,
            name: "dns-fix",
            content: "dns:\n  enable: true\n",
            format: .yaml,
            isGlobal: false,
            dryRun: false,
            restart: false
        )
        let id = try XCTUnwrap(added.id)
        XCTAssertEqual(added.name, "dns-fix")
        XCTAssertEqual(added.format, "yaml")
        XCTAssertEqual(added.kind, "local")
        XCTAssertFalse(added.dryRun)
        XCTAssertEqual(added.warnings, [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.overrideFilesDirectory.appendingPathComponent(id).appendingPathExtension("yaml").path
        ))

        let entries = OverrideCommandSupport.listEntries(try controller.overrides())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].name, "dns-fix")
        XCTAssertEqual(entries[0].format, "yaml")
        XCTAssertEqual(entries[0].kind, "local")
        XCTAssertFalse(entries[0].isGlobal)
        XCTAssertNil(entries[0].remoteURL)

        let content = try OverrideCommandSupport.content(controller: controller, id: id)
        XCTAssertEqual(content.id, id)
        XCTAssertEqual(content.content, "dns:\n  enable: true\n")
    }

    func testUpdateReplacesBodyAndKeepsIdentity() async throws {
        let controller = try makeController()
        let added = try addOverride(controller, name: "dns-fix")
        let id = added.id

        let updated = try await OverrideCommandSupport.update(
            controller: controller,
            id: id,
            content: "rules:\n  - MATCH,DIRECT\n",
            restart: false
        )

        XCTAssertEqual(updated.id, id)
        XCTAssertEqual(updated.name, "dns-fix")
        XCTAssertEqual(updated.kind, "local")
        XCTAssertEqual(updated.warnings, [])
        XCTAssertEqual(try controller.overrideContent(id: id), "rules:\n  - MATCH,DIRECT\n")
        XCTAssertEqual(try controller.overrides().count, 1)
    }

    func testReorderMovesListedIdsToFrontAndKeepsRemainder() async throws {
        let controller = try makeController()
        let first = try addOverride(controller, name: "first")
        let second = try addOverride(controller, name: "second")
        let third = try addOverride(controller, name: "third")

        let report = try await OverrideCommandSupport.reorder(
            controller: controller,
            ids: "\(third.id),\(first.id)",
            restart: false
        )

        XCTAssertEqual(report.ids, [third.id, first.id])
        XCTAssertEqual(try controller.overrides().map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(OverrideCommandSupport.listEntries(try controller.overrides()).map(\.index), [0, 1, 2])
    }

    func testDeleteRemovesItemAndBodyFile() async throws {
        let paths = try makeTemporaryPaths()
        let controller = KumoController(paths: paths)
        let added = try addOverride(controller, name: "dns-fix")
        let file = paths.overrideFilesDirectory.appendingPathComponent(added.id).appendingPathExtension("yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let preview = try await OverrideCommandSupport.delete(controller: controller, id: added.id, dryRun: true, restart: false)
        XCTAssertTrue(preview.dryRun)
        XCTAssertEqual(preview.name, "dns-fix")
        XCTAssertEqual(try controller.overrides().count, 1)

        let deleted = try await OverrideCommandSupport.delete(controller: controller, id: added.id, dryRun: false, restart: false)
        XCTAssertFalse(deleted.dryRun)
        XCTAssertEqual(deleted.id, added.id)
        XCTAssertTrue(try controller.overrides().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Id pre-validation

    func testUnknownIdsFailInsteadOfSilentNoOps() async throws {
        let paths = try makeTemporaryPaths()
        let controller = KumoController(paths: paths)

        let operations: [() async throws -> Void] = [
            { _ = try OverrideCommandSupport.content(controller: controller, id: "missing") },
            { _ = try await OverrideCommandSupport.update(controller: controller, id: "missing", content: "a: 1\n", restart: false) },
            { _ = try await OverrideCommandSupport.delete(controller: controller, id: "missing", dryRun: false, restart: false) },
            { _ = try await OverrideCommandSupport.reorder(controller: controller, ids: "missing", restart: false) }
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("expected unknown id to fail")
            } catch {
                XCTAssertEqual((error as? ValidationError)?.message, "Unknown override id: missing")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.overridesMetadataFile.path))
    }

    func testReorderRejectsDuplicatesAndLeavesOrderUnchanged() async throws {
        let controller = try makeController()
        let first = try addOverride(controller, name: "first")
        let second = try addOverride(controller, name: "second")

        do {
            _ = try await OverrideCommandSupport.reorder(
                controller: controller,
                ids: "\(first.id),\(first.id)",
                restart: false
            )
            XCTFail("expected duplicate ids to fail")
        } catch {
            XCTAssertEqual((error as? ValidationError)?.message, "Duplicate override id in --ids: \(first.id)")
        }
        do {
            _ = try await OverrideCommandSupport.reorder(controller: controller, ids: " , ", restart: false)
            XCTFail("expected empty ids to fail")
        } catch {}
        XCTAssertEqual(try controller.overrides().map(\.id), [first.id, second.id])
    }

    // MARK: - Dry run

    func testAddDryRunValidatesYAMLWithoutWriting() async throws {
        let paths = try makeTemporaryPaths()
        let controller = KumoController(paths: paths)

        do {
            _ = try await OverrideCommandSupport.addLocal(
                controller: controller,
                name: "broken",
                content: "dns: [unterminated\n",
                format: .yaml,
                isGlobal: false,
                dryRun: true,
                restart: false
            )
            XCTFail("expected invalid YAML to fail")
        } catch {
            guard let validation = error as? ValidationError else {
                return XCTFail("expected ValidationError, got \(error)")
            }
            XCTAssertTrue(validation.message.contains("override YAML is invalid"))
        }
        XCTAssertTrue(try controller.overrides().isEmpty)

        let report = try await OverrideCommandSupport.addLocal(
            controller: controller,
            name: "dns-fix",
            content: "dns:\n  enable: true\n",
            format: .yaml,
            isGlobal: false,
            dryRun: true,
            restart: false
        )
        XCTAssertTrue(report.dryRun)
        XCTAssertNil(report.id)
        XCTAssertTrue(try controller.overrides().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.overridesMetadataFile.path))
    }

    func testAddDryRunForJSOnlyPreviews() async throws {
        let controller = try makeController()

        let report = try await OverrideCommandSupport.addLocal(
            controller: controller,
            name: "js-fix",
            content: "function main(config) { return config }",
            format: .javascript,
            isGlobal: false,
            dryRun: true,
            restart: false
        )

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.format, "js")
        XCTAssertTrue(try controller.overrides().isEmpty)
    }

    func testAddDryRunForInvalidJSFailsWithoutWriting() async throws {
        let controller = try makeController()

        do {
            _ = try await OverrideCommandSupport.addLocal(
                controller: controller,
                name: "broken-js",
                content: "const x = 1",
                format: .javascript,
                isGlobal: false,
                dryRun: true,
                restart: false
            )
            XCTFail("expected invalid JavaScript to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("main(config)"), String(describing: error))
        }
        XCTAssertTrue(try controller.overrides().isEmpty)
    }

    // MARK: - Warnings

    func testAddDoesNotWarnThatJSAndGlobalAreInactive() async throws {
        let controller = try makeController()

        let report = try await OverrideCommandSupport.addLocal(
            controller: controller,
            name: "js-global",
            content: "function main(config) { return config }\n",
            format: .javascript,
            isGlobal: true,
            dryRun: false,
            restart: false
        )

        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(report.format, "js")
        XCTAssertTrue(report.isGlobal)

        let id = try XCTUnwrap(report.id)
        let updated = try await OverrideCommandSupport.update(
            controller: controller,
            id: id,
            content: "function main(config) { return config }\n",
            restart: false
        )
        XCTAssertEqual(updated.warnings, [])
        XCTAssertTrue(updated.isGlobal)
    }

    // MARK: - Restart handling

    func testRestartDecisionOnlyFiresWhenRequestedAndRunning() {
        var performed = 0

        XCTAssertFalse(OverrideCommandSupport.restartCore(requested: false, isRunning: true) { performed += 1 })
        XCTAssertFalse(OverrideCommandSupport.restartCore(requested: true, isRunning: false) { performed += 1 })
        XCTAssertEqual(performed, 0)

        XCTAssertTrue(OverrideCommandSupport.restartCore(requested: true, isRunning: true) { performed += 1 })
        XCTAssertEqual(performed, 1)
    }

    func testRestartFlagIsNoOpWithoutRunningCore() async throws {
        let controller = try makeController()

        let report = try await OverrideCommandSupport.addLocal(
            controller: controller,
            name: "dns-fix",
            content: "dns:\n  enable: true\n",
            format: .yaml,
            isGlobal: false,
            dryRun: false,
            restart: true
        )

        XCTAssertTrue(report.restartRequested)
        XCTAssertFalse(report.restarted)
        XCTAssertEqual(try controller.status().state, .stopped)
        XCTAssertEqual(try controller.overrides().count, 1)
    }

    // MARK: - Payloads and help

    func testOverridePayloadsEncodeStableKeys() async throws {
        let entry = OverrideListEntry(
            index: 1,
            id: "abc",
            name: "remote-fix",
            format: "js",
            kind: "remote",
            isGlobal: true,
            remoteURL: "https://example.com/override.yaml"
        )
        let entryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        XCTAssertEqual(entryObject["index"] as? Int, 1)
        XCTAssertEqual(entryObject["id"] as? String, "abc")
        XCTAssertEqual(entryObject["format"] as? String, "js")
        XCTAssertEqual(entryObject["kind"] as? String, "remote")
        XCTAssertEqual(entryObject["isGlobal"] as? Bool, true)
        XCTAssertEqual(entryObject["remoteURL"] as? String, "https://example.com/override.yaml")

        let report = OverrideMutationReport(
            id: nil,
            name: "dns-fix",
            format: "yaml",
            kind: "local",
            isGlobal: false,
            dryRun: true,
            warnings: ["w"],
            restartRequested: false,
            restarted: false
        )
        let reportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(reportObject["dryRun"] as? Bool, true)
        XCTAssertEqual(reportObject["restartRequested"] as? Bool, false)
        XCTAssertEqual(reportObject["restarted"] as? Bool, false)
        XCTAssertEqual(reportObject["warnings"] as? [String], ["w"])
    }

    func testHelpAndCompletionCoverOverrideCommands() {
        XCTAssertTrue(HelpText.topic(["override"]).contains("kumo override add --url <url>"))
        XCTAssertTrue(HelpText.topic(["override"]).contains("takes effect"))
        XCTAssertTrue(HelpText.long.contains("override reorder"))
        XCTAssertTrue(CompletionScripts.commandNames.split(separator: " ").map(String.init).contains("override"))
        XCTAssertTrue(HelpText.topLevel.contains("override"))
    }
}
