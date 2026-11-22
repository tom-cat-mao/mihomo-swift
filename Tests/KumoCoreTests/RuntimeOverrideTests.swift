import XCTest
@testable import KumoCoreKit

final class RuntimeOverrideTests: XCTestCase {
    func testYAMLAndJavaScriptOverridesApplyInExistingOrder() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            rules:
              - DOMAIN-SUFFIX,base.example,Proxy
            """
        )
        let overrides = [
            RuntimeOverride(
                name: "YAML before",
                format: .yaml,
                content: "rules+:\n  - DOMAIN-SUFFIX,yaml-before.example,DIRECT"
            ),
            RuntimeOverride(
                name: "JavaScript",
                format: .javascript,
                content: """
                function main(config) {
                    config.rules.push("DOMAIN-SUFFIX,javascript.example,Proxy")
                    config.javascriptApplied = true
                    return config
                }
                """
            ),
            RuntimeOverride(
                name: "YAML after",
                format: .yaml,
                content: "rules+:\n  - MATCH,DIRECT"
            )
        ]

        let runtime = try RuntimeConfigBuilder().build(profile: profile, overrides: overrides)

        XCTAssertLineOrder(
            runtime.yaml,
            [
                "DOMAIN-SUFFIX,base.example,Proxy",
                "DOMAIN-SUFFIX,yaml-before.example,DIRECT",
                "DOMAIN-SUFFIX,javascript.example,Proxy",
                "MATCH,DIRECT"
            ]
        )
        XCTAssertTrue(runtime.yaml.contains("javascriptApplied: true"))
    }

    func testJavaScriptReceivesPriorYAMLAndCanDeleteKeys() throws {
        let profile = Profile(
            name: "Test",
            source: .inline,
            rawYAML: """
            keep: profile
            remove: profile
            rules:
              - MATCH,DIRECT
            """
        )
        let overrides = [
            RuntimeOverride(name: "YAML", format: .yaml, content: "fromYAML: true\nremove: yaml"),
            RuntimeOverride(
                name: "JavaScript",
                format: .javascript,
                content: """
                function main(config) {
                    if (config.fromYAML !== true || config.remove !== "yaml") {
                        throw new Error("incorrect order")
                    }
                    delete config.remove
                    return config
                }
                """
            )
        ]

        let transformed = try RuntimeConfigBuilder().applyingOverrides(overrides, to: profile)

        XCTAssertTrue(transformed.rawYAML.contains("fromYAML: true"))
        XCTAssertTrue(transformed.rawYAML.contains("keep: profile"))
        XCTAssertFalse(transformed.rawYAML.contains("remove:"))
    }

    func testJavaScriptErrorContainsOverrideName() {
        let profile = Profile(name: "Test", source: .inline, rawYAML: "rules: []")
        let override = RuntimeOverride(name: "Named transform", format: .javascript, content: "const x = 1")

        XCTAssertThrowsError(
            try RuntimeConfigBuilder().build(profile: profile, overrides: [override])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Named transform"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("main(config)"), error.localizedDescription)
        }
    }

    func testFailedJavaScriptDoesNotWritePartialConfiguration() throws {
        let profile = Profile(name: "Test", source: .inline, rawYAML: "rules: []")
        let override = RuntimeOverride(
            name: "Broken transform",
            format: .javascript,
            content: "function main(config) { throw new Error(\"stop\") }"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("yaml")
        try Data("existing configuration".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try RuntimeConfigBuilder().write(profile: profile, overrides: [override], to: url)
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing configuration")
    }

    func testKumoControlledKeysStillWinAfterJavaScript() throws {
        let profile = Profile(name: "Test", source: .inline, rawYAML: "rules: []")
        let settings = CoreRuntimeSettings(
            mixedPort: 19090,
            tun: TunSettings(isEnabled: true, stack: "mips")
        )
        let override = RuntimeOverride(
            name: "Ownership attempt",
            format: .javascript,
            content: """
            function main(config) {
                config["mixed-port"] = 1
                config.tun = { enable: false, stack: "system" }
                return config
            }
            """
        )

        let runtime = try RuntimeConfigBuilder(runtimeSettings: settings).build(
            profile: profile,
            overrides: [override]
        )

        XCTAssertTrue(runtime.yaml.contains("mixed-port: 19090"))
        XCTAssertFalse(runtime.yaml.contains("mixed-port: 1\n"))
        XCTAssertTrue(runtime.yaml.contains("stack: mips"))
        XCTAssertTrue(runtime.yaml.contains("tun:\n  enable: true"))
    }

    private func XCTAssertLineOrder(
        _ yaml: String,
        _ fragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = yaml.startIndex
        for fragment in fragments {
            guard let range = yaml.range(of: fragment, range: lowerBound..<yaml.endIndex) else {
                XCTFail("Missing or out-of-order fragment: \(fragment)", file: file, line: line)
                return
            }
            lowerBound = range.upperBound
        }
    }
}
