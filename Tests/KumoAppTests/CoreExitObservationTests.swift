import Foundation
import XCTest
@testable import KumoApp
import KumoCoreKit

final class CoreExitObservationTests: XCTestCase {
    func testFirstObservationDoesNotReplayPersistedUnexpectedExit() {
        let persisted = exit(expected: false, second: 1)
        var observation = CoreExitObservation()

        XCTAssertNil(observation.observe(persisted))
        XCTAssertNil(observation.observe(persisted), "the same lastExit must be notified at most once")
    }

    func testOnlyNewUnexpectedExitsAreReturned() {
        let first = exit(expected: false, second: 1)
        let expectedStop = exit(expected: true, second: 2)
        let second = exit(expected: false, second: 3)
        var observation = CoreExitObservation()

        XCTAssertNil(observation.observe(nil))
        XCTAssertEqual(observation.observe(first), first)
        XCTAssertNil(observation.observe(first))
        XCTAssertNil(observation.observe(expectedStop), "expected stops never produce an alert")
        XCTAssertNil(observation.observe(expectedStop))
        XCTAssertEqual(observation.observe(second), second)
        XCTAssertNil(observation.observe(second))
    }

    private func exit(expected: Bool, second: TimeInterval) -> CoreExit {
        CoreExit(
            time: Date(timeIntervalSince1970: second),
            pid: 4242,
            exitCode: expected ? 0 : 1,
            expected: expected,
            message: expected ? "Stopped by request." : "Core crashed."
        )
    }
}
