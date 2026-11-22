import XCTest
@testable import KumoCoreKit

final class TunSettingsTests: XCTestCase {
    func testNewSettingsDefaultToMIPS() {
        XCTAssertEqual(TunSettings().stack, "mips")
    }

    func testLegacyStateWithoutStackKeepsMixedDefault() throws {
        let settings = try JSONDecoder().decode(TunSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.stack, "mixed")
    }

    func testSupportedStacksSurviveCodableRoundTrip() throws {
        for stack in ["mixed", "gvisor", "system", "mips"] {
            let encoded = try JSONEncoder().encode(TunSettings(stack: stack))
            let decoded = try JSONDecoder().decode(TunSettings.self, from: encoded)
            XCTAssertEqual(decoded.stack, stack)
        }
    }

    func testRuntimeYAMLEmitsMIPS() throws {
        let profile = Profile(name: "Test", source: .inline, rawYAML: "rules: []")
        let settings = CoreRuntimeSettings(tun: TunSettings(isEnabled: true, stack: "mips"))

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(profile: profile)

        XCTAssertTrue(runtime.yaml.contains("tun:\n  enable: true\n  stack: mips"))
    }
}
