import XCTest
@testable import KumoCoreKit

final class JavaScriptOverrideExecutorTests: XCTestCase {
    func testMainReceivesConfigAndReturnsModifiedObject() throws {
        let result = try JavaScriptOverrideExecutor().apply(
            script: """
            function main(config) {
                console.log("transforming")
                config["log-level"] = "debug"
                config.added = true
                return config
            }
            """,
            configuration: ["rules": ["MATCH,DIRECT"]]
        )

        XCTAssertEqual(result["log-level"] as? String, "debug")
        XCTAssertEqual(result["added"] as? Bool, true)
        XCTAssertEqual(result["rules"] as? [String], ["MATCH,DIRECT"])
    }

    func testMainCanModifyArrays() throws {
        let result = try JavaScriptOverrideExecutor().apply(
            script: """
            function main(config) {
                config.rules.unshift("DOMAIN-SUFFIX,first.example,DIRECT")
                config.rules.push("MATCH,Proxy")
                return config
            }
            """,
            configuration: ["rules": ["DOMAIN-SUFFIX,base.example,Proxy"]]
        )

        XCTAssertEqual(
            result["rules"] as? [String],
            [
                "DOMAIN-SUFFIX,first.example,DIRECT",
                "DOMAIN-SUFFIX,base.example,Proxy",
                "MATCH,Proxy"
            ]
        )
    }

    func testShellFileNetworkAndProcessAPIsAreNotExposed() throws {
        let result = try JavaScriptOverrideExecutor().apply(
            script: """
            function main(config) {
                config.capabilities = [
                    typeof readFile, typeof writeFile, typeof load, typeof run,
                    typeof fetch, typeof Worker, typeof process, typeof require
                ]
                return config
            }
            """,
            configuration: [:]
        )

        XCTAssertEqual(result["capabilities"] as? [String], Array(repeating: "undefined", count: 8))
    }

    func testMissingMainFails() {
        XCTAssertThrowsError(
            try JavaScriptOverrideExecutor().apply(
                script: "const value = 1",
                configuration: [:]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("main(config)"), error.localizedDescription)
        }
    }

    func testNonObjectResultFails() {
        XCTAssertThrowsError(
            try JavaScriptOverrideExecutor().apply(
                script: "function main(config) { return [] }",
                configuration: [:]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("must return an object"), error.localizedDescription)
        }
    }

    func testJavaScriptExceptionIsReturned() {
        XCTAssertThrowsError(
            try JavaScriptOverrideExecutor().apply(
                script: "function main(config) { throw new Error(\"boom\") }",
                configuration: [:]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("boom"), error.localizedDescription)
        }
    }

    func testInfiniteLoopTimesOutAndIsTerminated() {
        let executor = JavaScriptOverrideExecutor(timeout: 0.1)
        let start = Date()

        XCTAssertThrowsError(
            try executor.apply(
                script: "function main(config) { while (true) {} }",
                configuration: [:]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("timeout"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
