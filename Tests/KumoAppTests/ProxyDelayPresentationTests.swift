import SwiftUI
import XCTest
@testable import KumoApp
@testable import KumoCoreKit

final class ProxyDelayPresentationTests: XCTestCase {
    func testCurrentResultsUseLatencyAndFailureColors() {
        XCTAssertEqual(color(delay: 120, status: .success), .green)
        XCTAssertEqual(color(delay: 450, status: .success), .orange)
        XCTAssertEqual(color(delay: 0, status: .timeout), .red)
        XCTAssertEqual(color(delay: nil, status: .error), .red)
        XCTAssertEqual(color(delay: nil, status: .missing), .orange)
    }

    func testStaleHistoryRetainsLatencyColorsAndRedTimeout() {
        XCTAssertEqual(color(delay: 120, status: .stale), .green)
        XCTAssertEqual(color(delay: 450, status: .stale), .orange)
        XCTAssertEqual(color(delay: 0, status: .stale), .red)
        XCTAssertEqual(color(delay: nil, status: .stale), .secondary)
    }

    func testLegacyHistoryWithoutStatusAlsoRetainsColors() {
        XCTAssertEqual(color(delay: 120, status: nil), .green)
        XCTAssertEqual(color(delay: 450, status: nil), .orange)
        XCTAssertEqual(color(delay: 0, status: nil), .red)
        XCTAssertEqual(color(delay: nil, status: nil), .secondary)
    }

    func testStaleTextStillDistinguishesHistoryFromCurrentResults() {
        XCTAssertEqual(
            ProxyDelayPresentation.text(for: ProxyNode(name: "node", delay: 120, delayStatus: .stale)),
            "120 ms · stale"
        )
        XCTAssertEqual(
            ProxyDelayPresentation.text(for: ProxyNode(name: "node", delay: 0, delayStatus: .stale)),
            "stale timeout"
        )
    }

    private func color(delay: Int?, status: ProxyDelayStatus?) -> Color {
        ProxyDelayPresentation.color(
            for: ProxyNode(name: "node", delay: delay, delayStatus: status)
        )
    }
}
