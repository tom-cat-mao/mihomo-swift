import XCTest
@testable import KumoApp
@testable import KumoCoreKit

final class TunViewNormalizationTests: XCTestCase {
    func testUIStackNormalizationKeepsEverySupportedStack() {
        for stack in ["mixed", "gvisor", "system", "mips"] {
            XCTAssertEqual(normalizedTunStackForUI(stack), stack)
        }
    }

    func testUIStackNormalizationRetainsLegacyFallbackForUnknownValues() {
        XCTAssertEqual(normalizedTunStackForUI("unknown"), "mixed")
        XCTAssertEqual(normalizedTunStackForUI(""), "mixed")
    }
}
