import XCTest
@testable import KumoCLIKit
import KumoCoreKit

/// `kumo profile` parsing and command behavior, exercised against a hermetic
/// temporary app-support directory instead of the real one.
final class ProfileCommandTests: XCTestCase {
    private var root: URL?

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        super.tearDown()
    }

    private func makePaths() throws -> KumoPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        return KumoPaths(applicationSupportDirectory: root)
    }

    private func makeController() throws -> KumoController {
        KumoController(paths: try makePaths(), useServiceBackend: false)
    }

    @discardableResult
    private func seedProfile(
        _ controller: KumoController,
        id: String,
        name: String,
        remoteURL: URL?,
        autoUpdate: Bool = true,
        useProxy: Bool = false,
        rawYAML: String = "proxies: []\n"
    ) throws -> ProfileSummary {
        try ProfileRepository(paths: controller.paths).updateProfile(
            id: id,
            name: name,
            remoteURL: remoteURL,
            autoUpdate: autoUpdate,
            useProxy: useProxy,
            rawYAML: rawYAML
        )
    }

    // MARK: - Parsing

    func testProfileRefreshParsesURLAndIDModes() throws {
        let byURL = try KumoCommand.parseAsRoot([
            "profile", "refresh", "https://example.com/sub.yaml", "--use-proxy", "--json"
        ])
        let urlCommand = try XCTUnwrap(byURL as? KumoCommand.Profile.Refresh)
        XCTAssertEqual(urlCommand.url, "https://example.com/sub.yaml")
        XCTAssertNil(urlCommand.id)
        XCTAssertTrue(urlCommand.useProxy)

        let byID = try KumoCommand.parseAsRoot(["profile", "refresh", "--id", "abc"])
        let idCommand = try XCTUnwrap(byID as? KumoCommand.Profile.Refresh)
        XCTAssertNil(idCommand.url)
        XCTAssertEqual(idCommand.id, "abc")
        XCTAssertFalse(idCommand.useProxy)
    }

    func testProfileRefreshRequiresExactlyOneTarget() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "refresh"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot([
            "profile", "refresh", "https://example.com/sub.yaml", "--id", "abc"
        ]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "refresh", "not a url"]))
    }

    func testProfileUpdateParsesMergeFlags() throws {
        let command = try KumoCommand.parseAsRoot([
            "profile", "update", "abc",
            "--name", "Renamed",
            "--url", "https://example.com/a.yaml",
            "--no-auto-update",
            "--use-proxy",
            "--dry-run",
            "--json"
        ])
        let update = try XCTUnwrap(command as? KumoCommand.Profile.Update)
        XCTAssertEqual(update.id, "abc")
        XCTAssertEqual(update.name, "Renamed")
        XCTAssertEqual(update.url, "https://example.com/a.yaml")
        XCTAssertEqual(update.autoUpdate, false)
        XCTAssertEqual(update.useProxy, true)
        XCTAssertTrue(update.dryRun)

        let defaults = try KumoCommand.parseAsRoot(["profile", "update", "abc", "--auto-update", "--no-use-proxy"])
        let other = try XCTUnwrap(defaults as? KumoCommand.Profile.Update)
        XCTAssertEqual(other.autoUpdate, true)
        XCTAssertEqual(other.useProxy, false)
        XCTAssertNil(other.name)
        XCTAssertNil(other.url)
    }

    func testProfileUpdateRejectsEmptyOrInvalidInput() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "update", "abc"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "update", "abc", "--name", "   "]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "update", "abc", "--url", "not a url"]))
    }

    func testProfileEditRequiresExactlyOneSource() {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "edit", "abc", "--stdin", "--dry-run"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["profile", "edit", "abc", "--file", "/tmp/profile.yaml"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "edit", "abc"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot([
            "profile", "edit", "abc", "--stdin", "--file", "/tmp/profile.yaml"
        ]))
    }

    // MARK: - Update backfill

    func testProfileUpdateBackfillsOmittedMetadata() async throws {
        let controller = try makeController()
        let repository = ProfileRepository(paths: controller.paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/a.yaml"))
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: remoteURL)

        let report = try await KumoCommand.Profile.Update.perform(
            controller: controller,
            id: "airport",
            name: "Renamed",
            urlString: nil,
            autoUpdate: false,
            useProxy: nil,
            dryRun: false
        )

        XCTAssertEqual(report.name, "Renamed")
        XCTAssertEqual(report.kind, .remote)
        XCTAssertEqual(report.remoteURL, remoteURL, "omitting --url must not demote the subscription")
        XCTAssertFalse(report.autoUpdate)
        XCTAssertFalse(report.useProxy, "omitted --use-proxy keeps the stored value")
        XCTAssertFalse(report.dryRun)

        let stored = try XCTUnwrap(repository.listProfiles().first { $0.id == "airport" })
        XCTAssertEqual(stored.remoteURL, remoteURL)
        XCTAssertEqual(stored.kind, .remote)
        XCTAssertFalse(stored.useProxy)
        XCTAssertEqual(try repository.profileContent(id: "airport"), "proxies: []\n")
    }

    func testProfileUpdateDryRunReportsMergedMetadataWithoutWriting() async throws {
        let controller = try makeController()
        let repository = ProfileRepository(paths: controller.paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/a.yaml"))
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: remoteURL)

        let report = try await KumoCommand.Profile.Update.perform(
            controller: controller,
            id: "airport",
            name: "Renamed",
            urlString: nil,
            autoUpdate: nil,
            useProxy: true,
            dryRun: true
        )

        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.name, "Renamed")
        XCTAssertEqual(report.remoteURL, remoteURL)
        XCTAssertTrue(report.useProxy)
        XCTAssertTrue(report.autoUpdate, "omitted --auto-update keeps the stored value")

        let stored = try XCTUnwrap(repository.listProfiles().first { $0.id == "airport" })
        XCTAssertEqual(stored.name, "Airport", "dry-run must not write")
        XCTAssertFalse(stored.useProxy)
    }

    func testProfileUpdatePromotesLocalProfileWhenURLProvided() async throws {
        let controller = try makeController()
        try seedProfile(controller, id: "local1", name: "Local", remoteURL: nil)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/sub.yaml"))

        let report = try await KumoCommand.Profile.Update.perform(
            controller: controller,
            id: "local1",
            name: nil,
            urlString: remoteURL.absoluteString,
            autoUpdate: nil,
            useProxy: nil,
            dryRun: false
        )

        XCTAssertEqual(report.kind, .remote)
        XCTAssertEqual(report.remoteURL, remoteURL)
        XCTAssertEqual(report.name, "Local", "omitted --name keeps the stored value")
    }

    func testProfileUpdateRejectsUnknownIDAndSubStoreURLEdit() async throws {
        let controller = try makeController()

        do {
            _ = try await KumoCommand.Profile.Update.perform(
                controller: controller,
                id: "nope",
                name: "X",
                urlString: nil,
                autoUpdate: nil,
                useProxy: nil,
                dryRun: false
            )
            XCTFail("expected an unknown-profile error")
        } catch {
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }

        let root = try XCTUnwrap(self.root)
        let source = root.appendingPathComponent("substore.yaml")
        try "proxies: []\n".write(to: source, atomically: true, encoding: .utf8)
        _ = try await ProfileRepository(paths: controller.paths).saveSubStoreProfile(
            name: "Sub",
            subStorePath: source.absoluteString,
            downloadURL: source,
            autoUpdate: true,
            preferredID: "sub1",
            makeCurrent: false
        )

        do {
            _ = try await KumoCommand.Profile.Update.perform(
                controller: controller,
                id: "sub1",
                name: nil,
                urlString: "https://example.com/other.yaml",
                autoUpdate: nil,
                useProxy: nil,
                dryRun: false
            )
            XCTFail("expected a Sub-Store URL guard")
        } catch {
            XCTAssertTrue(String(describing: error).contains("managed by Sub-Store"))
        }
    }

    // MARK: - Edit

    func testProfileEditValidatesYAMLAndWritesInPlace() throws {
        let controller = try makeController()
        let repository = ProfileRepository(paths: controller.paths)
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/a.yaml"))
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: remoteURL)

        do {
            _ = try KumoCommand.Profile.Edit.perform(
                controller: controller,
                id: "airport",
                rawYAML: "proxies: [",
                dryRun: false
            )
            XCTFail("invalid YAML must fail before writing")
        } catch {
            XCTAssertTrue(String(describing: error).contains("not valid YAML"))
        }
        XCTAssertEqual(try repository.profileContent(id: "airport"), "proxies: []\n")

        let dryRun = try KumoCommand.Profile.Edit.perform(
            controller: controller,
            id: "airport",
            rawYAML: "proxies:\n  - name: new\n",
            dryRun: true
        )
        XCTAssertTrue(dryRun.dryRun)
        XCTAssertEqual(try repository.profileContent(id: "airport"), "proxies: []\n")

        let written = try KumoCommand.Profile.Edit.perform(
            controller: controller,
            id: "airport",
            rawYAML: "proxies:\n  - name: new\n",
            dryRun: false
        )
        XCTAssertFalse(written.dryRun)
        XCTAssertEqual(written.name, "Airport")
        XCTAssertEqual(try repository.profileContent(id: "airport"), "proxies:\n  - name: new\n")

        let stored = try XCTUnwrap(repository.listProfiles().first { $0.id == "airport" })
        XCTAssertEqual(stored.remoteURL, remoteURL, "editing YAML must not demote the subscription")
        XCTAssertEqual(stored.name, "Airport")
    }

    func testProfileEditRejectsUnknownIDAndNonMappingYAML() throws {
        let controller = try makeController()
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: nil)

        do {
            _ = try KumoCommand.Profile.Edit.perform(
                controller: controller,
                id: "nope",
                rawYAML: "proxies: []\n",
                dryRun: true
            )
            XCTFail("expected an unknown-profile error")
        } catch {
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }

        XCTAssertThrowsError(
            try KumoCommand.Profile.Edit.perform(
                controller: controller,
                id: "airport",
                rawYAML: "- just\n- a list\n",
                dryRun: true
            )
        )
    }

    // MARK: - Content

    func testProfileContentPreValidatesID() throws {
        let controller = try makeController()
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: nil, rawYAML: "proxies: []\n")

        let payload = try KumoCommand.Profile.Content.perform(controller: controller, id: "airport")
        XCTAssertEqual(payload.id, "airport")
        XCTAssertEqual(payload.content, "proxies: []\n")

        // The repository falls back to the current profile for an unknown id;
        // the CLI must fail instead of printing the wrong profile.
        XCTAssertNoThrow(try ProfileRepository(paths: controller.paths).profileContent(id: "nope"))
        XCTAssertThrowsError(try KumoCommand.Profile.Content.perform(controller: controller, id: "nope")) { error in
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }
    }

    // MARK: - Groups and nodes

    func testProfileGroupsAndNodesParse() throws {
        let groups = try KumoCommand.parseAsRoot(["profile", "groups", "abc"])
        let groupsCommand = try XCTUnwrap(groups as? KumoCommand.Profile.Groups)
        XCTAssertEqual(groupsCommand.id, "abc")

        let nodes = try KumoCommand.parseAsRoot(["profile", "nodes", "abc", "--json"])
        let nodesCommand = try XCTUnwrap(nodes as? KumoCommand.Profile.Nodes)
        XCTAssertEqual(nodesCommand.id, "abc")
        XCTAssertTrue(nodesCommand.options.json)

        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "groups"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["profile", "nodes"]))
    }

    func testProfileGroupsParsesYAMLWithoutARunningCore() async throws {
        let controller = try makeController()
        try seedProfile(
            controller,
            id: "airport",
            name: "Airport",
            remoteURL: nil,
            rawYAML: """
            proxies:
              - name: HK-01
                server: hk.example.com
                port: 443
              - name: US-01
                server: us.example.com
                port: 8443
            proxy-groups:
              - name: Proxy
                type: select
                proxies: [HK-01, US-01]
              - name: Empty
                type: select
                proxies: []
            """
        )

        XCTAssertEqual(try controller.status().state, .stopped)
        let payload = try await KumoCommand.Profile.Groups.perform(controller: controller, id: "airport")

        XCTAssertEqual(payload.id, "airport")
        XCTAssertEqual(payload.groups.map(\.name), ["Proxy"], "groups without members are dropped")
        XCTAssertEqual(payload.groups.first?.proxies.map(\.name), ["HK-01", "US-01"])
        XCTAssertNil(payload.groups.first?.selectedProxyName, "selection is only known while the core runs")
    }

    func testProfileNodesListsServersSortedByName() async throws {
        let controller = try makeController()
        try seedProfile(
            controller,
            id: "airport",
            name: "Airport",
            remoteURL: nil,
            rawYAML: """
            proxies:
              - name: US-01
                server: us.example.com
                port: 8443
              - name: HK-01
                server: hk.example.com
                port: 443
              - name: No-Port
                server: no-port.example.com
            """
        )

        let payload = try await KumoCommand.Profile.Nodes.perform(controller: controller, id: "airport")

        XCTAssertEqual(payload.id, "airport")
        XCTAssertEqual(payload.nodes.map(\.name), ["HK-01", "No-Port", "US-01"])
        XCTAssertEqual(payload.nodes.first, ProfileNodeEntry(name: "HK-01", server: "hk.example.com", port: 443))
        XCTAssertEqual(payload.nodes.last, ProfileNodeEntry(name: "US-01", server: "us.example.com", port: 8443))
        XCTAssertNil(payload.nodes[1].port)
    }

    func testProfileGroupsAndNodesRejectUnknownID() async throws {
        let controller = try makeController()
        try seedProfile(controller, id: "airport", name: "Airport", remoteURL: nil)

        // The parse cache falls back to the current profile for an unknown
        // id; both commands must fail instead of previewing the wrong profile.
        do {
            _ = try await KumoCommand.Profile.Groups.perform(controller: controller, id: "nope")
            XCTFail("expected an unknown-profile error")
        } catch {
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }
        do {
            _ = try await KumoCommand.Profile.Nodes.perform(controller: controller, id: "nope")
            XCTFail("expected an unknown-profile error")
        } catch {
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }
    }

    // MARK: - Refresh

    func testProfileRefreshByIDRefreshesInPlace() async throws {
        let controller = try makeController()
        let repository = ProfileRepository(paths: controller.paths)
        let root = try XCTUnwrap(self.root)
        let subscription = root.appendingPathComponent("subscription.yaml")
        try "proxies: []\n".write(to: subscription, atomically: true, encoding: .utf8)
        try seedProfile(controller, id: "sub1", name: "Sub", remoteURL: subscription)
        try repository.saveProfile(
            Profile(name: "Other", source: .inline, rawYAML: "proxies: []\n"),
            preferredID: "other"
        )

        try "proxies:\n  - name: updated\n".write(to: subscription, atomically: true, encoding: .utf8)
        let report = try await KumoCommand.Profile.Refresh.refreshByID(
            controller: controller,
            id: "sub1",
            useProxy: false
        )

        XCTAssertEqual(report.profile.id, "sub1")
        XCTAssertEqual(report.profile.name, "Sub", "in-place refresh preserves the stored name")
        XCTAssertFalse(report.profile.isCurrent)
        XCTAssertFalse(report.restartedCore)
        XCTAssertEqual(try repository.profileContent(id: "sub1"), "proxies:\n  - name: updated\n")
        XCTAssertEqual(try repository.currentProfileSummary().id, "other")
    }

    func testProfileRefreshByIDNeverRestartsAStoppedCore() async throws {
        let controller = try makeController()
        let repository = ProfileRepository(paths: controller.paths)
        let root = try XCTUnwrap(self.root)
        let subscription = root.appendingPathComponent("subscription.yaml")
        try "proxies: []\n".write(to: subscription, atomically: true, encoding: .utf8)
        try seedProfile(controller, id: "sub1", name: "Sub", remoteURL: subscription)
        try repository.setCurrentProfile(id: "sub1")

        let report = try await KumoCommand.Profile.Refresh.refreshByID(
            controller: controller,
            id: "sub1",
            useProxy: false
        )

        XCTAssertTrue(report.profile.isCurrent)
        XCTAssertFalse(report.restartedCore, "a stopped core has nothing to restart")
        XCTAssertEqual(try controller.status().state, .stopped)
    }

    func testProfileRefreshByIDRejectsUnknownIDAndProxyWithoutCore() async throws {
        let controller = try makeController()

        do {
            _ = try await KumoCommand.Profile.Refresh.refreshByID(controller: controller, id: "nope", useProxy: false)
            XCTFail("expected an unknown-profile error")
        } catch {
            XCTAssertEqual(String(describing: error), "Unknown profile id: nope")
        }

        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/sub.yaml"))
        try seedProfile(controller, id: "sub1", name: "Sub", remoteURL: remoteURL)

        do {
            _ = try await KumoCommand.Profile.Refresh.refreshByID(controller: controller, id: "sub1", useProxy: true)
            XCTFail("expected the proxy-without-core error")
        } catch let error as KumoError {
            XCTAssertEqual(
                error,
                .invalidArguments("Start Kumo before updating this profile through the local proxy.")
            )
        }
    }
}
