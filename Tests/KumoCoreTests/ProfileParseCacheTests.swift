import XCTest
@testable import KumoCoreKit

final class ProfileParseCacheTests: XCTestCase {
    // MARK: - Invalidation

    func testProxyGroupsAreMemoizedUntilTheFileChanges() async throws {
        let (cache, profileURL) = try makeCache(profileID: "test", yaml: groupYAML(named: "Alpha"))

        let first = try await cache.proxyGroups(profileID: "test")
        XCTAssertEqual(first.map(\.name), ["Alpha"])

        // Same file, so the memo answers with an equal value.
        let repeatLookup = try await cache.proxyGroups(profileID: "test")
        XCTAssertEqual(repeatLookup, first)

        // New content: a different body length and a bumped modification date,
        // so the identity cannot match even on a coarse-grained filesystem.
        try write(groupYAML(named: "Beta renamed"), to: profileURL, bumpingModificationDate: true)

        let afterChange = try await cache.proxyGroups(profileID: "test")
        XCTAssertEqual(afterChange.map(\.name), ["Beta renamed"])
    }

    func testNodesAreMemoizedUntilTheFileChanges() async throws {
        let (cache, profileURL) = try makeCache(profileID: "test", yaml: nodeYAML(name: "one", server: "one.example.com"))

        let first = try await cache.nodes(profileID: "test")
        XCTAssertEqual(first["one"]?.server, "one.example.com")

        let repeatLookup = try await cache.nodes(profileID: "test")
        XCTAssertEqual(repeatLookup, first)

        try write(nodeYAML(name: "two", server: "two.example.com"), to: profileURL, bumpingModificationDate: true)

        let afterChange = try await cache.nodes(profileID: "test")
        XCTAssertNil(afterChange["one"])
        XCTAssertEqual(afterChange["two"]?.server, "two.example.com")
    }

    /// A change that keeps the byte count identical still invalidates, because
    /// the modification date is part of the key.
    func testSameSizeRewriteInvalidatesOnModificationDate() async throws {
        let (cache, profileURL) = try makeCache(profileID: "test", yaml: groupYAML(named: "Alpha"))

        let before = try await cache.proxyGroups(profileID: "test").map(\.name)
        XCTAssertEqual(before, ["Alpha"])

        // "Alpha" and "Bravo" are both five characters, so the size is unchanged.
        try write(groupYAML(named: "Bravo"), to: profileURL, bumpingModificationDate: true)

        let after = try await cache.proxyGroups(profileID: "test").map(\.name)
        XCTAssertEqual(after, ["Bravo"])
    }

    // MARK: - Default-profile fallback

    /// With no profile file at all, `loadProfile` serves the inline default
    /// whose `proxy-groups:` describes a single DIRECT group. The cache must
    /// parse that body rather than failing or parsing the requested file.
    func testInlineDefaultFallbackIsPreserved() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let cache = ProfileParseCache(profiles: ProfileRepository(paths: paths))

        let groups = try await cache.proxyGroups(profileID: "missing")
        XCTAssertEqual(groups.map(\.name), ["Proxy"])
        XCTAssertEqual(groups.first?.proxies.map(\.name), ["DIRECT"])

        // The inline default has no `proxies:` section.
        let nodes = try await cache.nodes(profileID: "missing")
        XCTAssertTrue(nodes.isEmpty)
    }

    /// A missing profile falls back to `default.yaml`, and the cache follows that
    /// same chain instead of parsing the requested (absent) file.
    func testMissingProfileFallsBackToDefaultProfileFile() async throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try FileManager.default.createDirectory(at: paths.profilesDirectory, withIntermediateDirectories: true)
        try write(
            groupYAML(named: "From default file"),
            to: paths.profilesDirectory.appendingPathComponent("default.yaml")
        )

        let cache = ProfileParseCache(profiles: ProfileRepository(paths: paths))

        let groups = try await cache.proxyGroups(profileID: "not-on-disk")
        XCTAssertEqual(groups.map(\.name), ["From default file"])
    }

    // MARK: - Helpers

    private func makeCache(profileID: String, yaml: String) throws -> (ProfileParseCache, URL) {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        try FileManager.default.createDirectory(at: paths.profilesDirectory, withIntermediateDirectories: true)
        let profileURL = paths.profilesDirectory.appendingPathComponent("\(profileID).yaml")
        try write(yaml, to: profileURL)
        return (ProfileParseCache(profiles: ProfileRepository(paths: paths)), profileURL)
    }

    private func groupYAML(named name: String) -> String {
        """
        proxies:
          - name: node
            server: example.com
            port: 443
        proxy-groups:
          - name: \(name)
            type: select
            proxies:
              - node
        """
    }

    private func nodeYAML(name: String, server: String) -> String {
        """
        proxies:
          - name: \(name)
            server: \(server)
            port: 443
        """
    }

    private func write(_ yaml: String, to url: URL, bumpingModificationDate: Bool = false) throws {
        try yaml.data(using: .utf8)?.write(to: url, options: .atomic)
        if bumpingModificationDate {
            // Guarantee a distinct identity regardless of timestamp granularity.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(60)],
                ofItemAtPath: url.path
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
