import XCTest
@testable import KumoCLIKit
import KumoCoreKit

final class TunSettingsCommandTests: XCTestCase {
    func testCLIValidationAcceptsMIPSAndExistingStacks() {
        for stack in ["mixed", "gvisor", "system", "mips"] {
            XCTAssertNoThrow(try validateTunSettings(TunSettings(stack: stack)))
        }
    }

    func testCLIValidationRejectsUnknownStack() {
        XCTAssertThrowsError(try validateTunSettings(TunSettings(stack: "unknown"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Valid stacks"), message)
            XCTAssertTrue(message.contains("mips"), message)
        }
    }

    func testTUNHelpDocumentsStacksAndMIPSVersion() {
        for topic in [["tun"], ["tun", "settings"]] {
            let help = HelpText.topic(topic)
            for stack in ["mixed", "gvisor", "system", "mips"] {
                XCTAssertTrue(help.contains(stack), help)
            }
            XCTAssertTrue(help.contains("1.19.32"), help)
        }
    }
}
