import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class ConfigRuntimeCommandTests: XCTestCase {
    // MARK: - Parsing

    func testConfigGetParsesWholeSettingsAndKeys() throws {
        let whole = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "get"]) as? KumoCommand.Config.Get)
        XCTAssertNil(whole.key)

        let key = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "get", "mixedPort"]) as? KumoCommand.Config.Get)
        XCTAssertEqual(key.key, "mixedPort")

        let geo = try XCTUnwrap(try KumoCommand.parseAsRoot(["c", "get", "geoData", "--json"]) as? KumoCommand.Config.Get)
        XCTAssertEqual(geo.key, "geoData")
        XCTAssertTrue(geo.options.json)
    }

    func testConfigGetRejectsUnknownKeyListingValidOnes() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "get", "answer"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Unknown settings key 'answer'"), message)
            for key in ["mixedPort", "allowLan", "logLevel", "ipv6", "findProcessMode", "geoData"] {
                XCTAssertTrue(message.contains(key), "missing \(key) in: \(message)")
            }
        }
    }

    func testConfigSetParsesFlagsAndPatchInputs() throws {
        let flags = try XCTUnwrap(try KumoCommand.parseAsRoot([
            "config", "set",
            "--mixed-port", "7897",
            "--allow-lan", "true",
            "--log-level", "warning",
            "--ipv6", "false",
            "--find-process-mode", "strict"
        ]) as? KumoCommand.Config.Set)
        XCTAssertEqual(flags.mixedPort, 7897)
        XCTAssertEqual(flags.allowLan, true)
        XCTAssertEqual(flags.logLevel, "warning")
        XCTAssertEqual(flags.ipv6, false)
        XCTAssertEqual(flags.findProcessMode, "strict")
        XCTAssertFalse(flags.dryRun)

        let file = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "set", "--file", "/tmp/settings.json", "--dry-run"]) as? KumoCommand.Config.Set)
        XCTAssertEqual(file.file, "/tmp/settings.json")
        XCTAssertTrue(file.dryRun)

        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["config", "set", "--stdin", "--json"]))
    }

    func testConfigSetRejectsConflictingOrMissingInput() {
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--stdin", "--file", "/tmp/settings.json"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--mixed-port", "7897", "--stdin"]))
    }

    func testConfigSetValidatesPortAndEnums() {
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["config", "set", "--mixed-port", "1"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["config", "set", "--mixed-port", "65535"]))
        XCTAssertNoThrow(try KumoCommand.parseAsRoot(["config", "set", "--log-level", "debug", "--find-process-mode", "off"]))

        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--mixed-port", "0"])) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("1...65535"), Self.failureMessage(error))
        }
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--mixed-port", "65536"]))
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--log-level", "trace"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Valid levels"), message)
            XCTAssertTrue(message.contains("silent"), message)
        }
        XCTAssertThrowsError(try KumoCommand.parseAsRoot(["config", "set", "--find-process-mode", "sometimes"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Valid modes"), message)
            XCTAssertTrue(message.contains("always"), message)
        }
    }

    // MARK: - Unknown-key rejection

    func testConfigSetPatchRejectsUnknownKeysAndPointsAtDedicatedCommands() throws {
        XCTAssertThrowsError(try validateConfigRuntimePatchKeys(["logLevel", "nope"])) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Unknown key in the runtime settings patch: nope."), message)
            XCTAssertTrue(message.contains("Valid keys: allowLan, findProcessMode, ipv6, logLevel, mixedPort."), message)
        }
        XCTAssertThrowsError(try validateConfigRuntimePatchKeys(["nope", "other"])) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("Unknown keys in the runtime settings patch: nope, other."))
        }

        let pointers = ["dns": "kumo dns set", "sniffer": "kumo sniffer set", "tun": "kumo tun settings"]
        for (key, command) in pointers {
            XCTAssertThrowsError(try validateConfigRuntimePatchKeys([key])) { error in
                let message = Self.failureMessage(error)
                XCTAssertTrue(message.contains("`\(key)` settings are not part of `kumo config set`"), message)
                XCTAssertTrue(message.contains(command), message)
            }
        }

        XCTAssertNoThrow(try validateConfigRuntimePatchKeys(Array(configRuntimePatchKeys)))
    }

    func testSettingsPatchRejectsUnknownKeysWithValidKeyList() {
        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"{"nope": 1}"#.utf8), to: DnsSettings(), name: "DnsSettings")) { error in
            let message = Self.failureMessage(error)
            XCTAssertTrue(message.contains("Unknown key in the DnsSettings patch: nope."), message)
            XCTAssertTrue(message.contains("cacheAlgorithm"), message)
            XCTAssertTrue(message.contains("nameserver"), message)
        }
        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"{"tlsPort": [443]}"#.utf8), to: SnifferSettings(), name: "SnifferSettings")) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("Valid keys: ") && Self.failureMessage(error).contains("tlsPorts"))
        }
        XCTAssertThrowsError(try applyingSettingsPatch(Data(#"{"mtus": 1500}"#.utf8), to: TunSettings(), name: "TunSettings")) { error in
            XCTAssertTrue(Self.failureMessage(error).contains("mtu"))
        }
    }

    func testPatchKeyAllowlistsMatchCodableKeys() throws {
        try assertPatchKeysMatch(DnsSettings.self, instance: DnsSettings())
        try assertPatchKeysMatch(SnifferSettings.self, instance: SnifferSettings())
        try assertPatchKeysMatch(TunSettings.self, instance: TunSettings(device: "utun9"))
    }

    // MARK: - Applying and dry-run

    func testConfigSetDryRunDoesNotWriteState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let controller = KumoController(paths: KumoPaths(applicationSupportDirectory: root), useServiceBackend: false)

        let preview = try await applyConfigRuntimeSet(to: controller, mixedPort: 7897, dryRun: true)
        XCTAssertEqual(preview.mixedPort, 7897)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.paths.stateFile.path))

        let applied = try await applyConfigRuntimeSet(to: controller, mixedPort: 7897, allowLan: true, dryRun: false)
        XCTAssertEqual(applied.mixedPort, 7897)
        XCTAssertTrue(FileManager.default.fileExists(atPath: controller.paths.stateFile.path))

        let stored = try controller.status()
        XCTAssertEqual(stored.runtimeSettings?.mixedPort, 7897)
        XCTAssertEqual(stored.runtimeSettings?.allowLAN, true)
        XCTAssertEqual(stored.proxyPorts.mixedPort, 7897)

        let patchPreview = try await applyConfigRuntimeSet(
            to: controller,
            patchData: Data(#"{"mixedPort": 7898, "logLevel": "debug"}"#.utf8),
            dryRun: true
        )
        XCTAssertEqual(patchPreview.mixedPort, 7898)
        XCTAssertEqual(patchPreview.logLevel, "debug")
        XCTAssertEqual(patchPreview.allowLAN, true)
        XCTAssertEqual(try controller.status().runtimeSettings?.mixedPort, 7897)
    }

    func testConfigSetPatchRejectsUnknownKeysBeforeWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let controller = KumoController(paths: KumoPaths(applicationSupportDirectory: root), useServiceBackend: false)

        do {
            _ = try await applyConfigRuntimeSet(to: controller, patchData: Data(#"{"nope": true}"#.utf8), dryRun: false)
            XCTFail("expected unknown-key rejection")
        } catch {
            XCTAssertTrue(Self.failureMessage(error).contains("Valid keys"))
        }
        do {
            _ = try await applyConfigRuntimeSet(to: controller, patchData: Data(#"{"dns": {"isEnabled": true}}"#.utf8), dryRun: false)
            XCTFail("expected dedicated-command rejection")
        } catch {
            XCTAssertTrue(Self.failureMessage(error).contains("kumo dns set"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.paths.stateFile.path))
    }

    func testConfigSetFallsBackToStoredProxyPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = KumoPaths(applicationSupportDirectory: root)
        var status = CoreStatus()
        status.proxyPorts.mixedPort = 8899
        try CoreStateStore(paths: paths).save(status)

        let controller = KumoController(paths: paths, useServiceBackend: false)
        let merged = try await applyConfigRuntimeSet(to: controller, allowLan: true, dryRun: true)

        XCTAssertEqual(merged.mixedPort, 8899)
        XCTAssertTrue(merged.allowLAN)
    }

    // MARK: - Secret

    func testConfigSecretParsesShowAndSet() throws {
        let show = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "secret", "--json"]) as? KumoCommand.Config.Secret)
        XCTAssertNil(show.set)
        XCTAssertTrue(show.options.json)

        let set = try XCTUnwrap(try KumoCommand.parseAsRoot(["config", "secret", "--set", "s3cret-token"]) as? KumoCommand.Config.Secret)
        XCTAssertEqual(set.set, "s3cret-token")
    }

    func testConfigSecretReportNeverCarriesTheSecret() throws {
        let data = try JSONEncoder().encode(ConfigSecretReport(isSet: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["isSet"])
        XCTAssertEqual(object["isSet"] as? Bool, true)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("s3cret") ?? true)
    }

    // MARK: - Help topics

    func testConfigHelpTopicsCoverGetSetAndSecret() {
        XCTAssertTrue(HelpText.topic(["config"]).contains("kumo config get"))
        XCTAssertTrue(HelpText.topic(["config", "get"]).contains("mixedPort"))
        XCTAssertTrue(HelpText.topic(["config", "set"]).contains("--mixed-port"))
        XCTAssertTrue(HelpText.topic(["config", "set"]).contains("1...65535"))
        XCTAssertTrue(HelpText.topic(["config", "secret"]).contains("set=true|false"))
        XCTAssertTrue(HelpText.topic(["config", "secret"]).contains("next time the core starts"))
    }

    // MARK: - Helpers

    private func assertPatchKeysMatch<T: Codable & SettingsPatchKeyProviding>(
        _ type: T.Type,
        instance: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(instance)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        XCTAssertEqual(T.patchKeys, Set(object.keys), "\(type) allowlist drifted from its Codable keys", file: file, line: line)
    }

    private static func failureMessage(_ error: Error) -> String {
        [(error as? LocalizedError)?.errorDescription, String(describing: error)]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
