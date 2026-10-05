import Foundation
import XCTest
@testable import KumoCoreKit

final class CoreStateStoreTests: XCTestCase {
    func testStateStorePersistsStatus() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        let status = CoreStatus(
            state: .running,
            pid: 42,
            mode: .direct,
            systemProxyEnabled: true,
            message: "ok"
        )

        try store.save(status)

        XCTAssertEqual(try store.load(), status)
    }

    // MARK: - Ownership record serialization

    /// A nil record must be omitted from the payload so a state written by
    /// this build stays byte-compatible with builds that predate the field.
    func testNilOwnerTierIsNotSerialized() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        try store.save(CoreStatus(state: .running, pid: 42))

        let object = try stateObject(at: paths.stateFile)

        XCTAssertNil(object["ownerTier"])
        XCTAssertNil(try store.load().ownerTier)
    }

    /// Legacy `state.json` — no `ownerTier` key — must load with a nil record;
    /// read paths treat that as "unknown" and fall back to routing inference.
    func testLegacyStateWithoutOwnerTierLoadsAsUnrecorded() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        try store.save(CoreStatus(
            state: .running,
            pid: 42,
            runtimeSettings: CoreRuntimeSettings(tun: TunSettings(isEnabled: false))
        ))

        var object = try stateObject(at: paths.stateFile)
        object.removeValue(forKey: "ownerTier")
        try write(object, to: paths.stateFile)

        let decoded = try store.load()

        XCTAssertNil(decoded.ownerTier)
        XCTAssertEqual(decoded.state, .running)
        XCTAssertEqual(decoded.pid, 42)
        XCTAssertEqual(decoded.runtimeSettings?.tun?.isEnabled, false)
    }

    func testOwnerTierRoundTripsThroughTheStateStore() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        let status = CoreStatus(state: .running, pid: 7, ownerTier: .userAgent)

        try store.save(status)

        XCTAssertEqual(try store.load(), status)
        XCTAssertEqual(try stateObject(at: paths.stateFile)["ownerTier"] as? String, "userAgent")
    }

    /// A newer build may add fields; an older build must keep decoding the
    /// state it already knows. Decoding ignores keys it has no property for.
    func testUnknownStateKeysAreIgnored() throws {
        let paths = KumoPaths(applicationSupportDirectory: temporaryDirectory())
        let store = CoreStateStore(paths: paths)
        try store.save(CoreStatus(state: .running, pid: 7, ownerTier: .rootService))

        var object = try stateObject(at: paths.stateFile)
        object["futureField"] = ["nested": true]
        try write(object, to: paths.stateFile)

        let decoded = try store.load()

        XCTAssertEqual(decoded.ownerTier, .rootService)
        XCTAssertEqual(decoded.pid, 7)
    }

    /// A tier string written by a future build decodes as `.unknown`, never as
    /// a decode failure that would make the whole `state.json` unreadable.
    func testUnrecognizedOwnerTierStringDecodesAsUnknown() throws {
        let json = """
        {
          "state": "running",
          "mode": "rule",
          "endpoint": { "host": "127.0.0.1", "port": 9097, "secret": "" },
          "proxyPorts": { "mixedPort": 7890 },
          "systemProxyEnabled": false,
          "ownerTier": "futureTier"
        }
        """

        let decoded = try JSONDecoder().decode(CoreStatus.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.ownerTier, .unknown)
        XCTAssertEqual(decoded.state, .running)
    }

    // MARK: - Helpers

    private func stateObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
