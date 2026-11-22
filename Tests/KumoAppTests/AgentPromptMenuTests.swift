import XCTest
@testable import KumoApp
import KumoCoreKit

final class AgentPromptMenuTests: XCTestCase {
    func testEveryMainDestinationMapsToAnExistingGuideWithoutPlaceholders() {
        for destination in SidebarDestination.allCases {
            if destination == .subStore {
                XCTAssertNil(destination.agentPromptPage)
                continue
            }
            let page = try? XCTUnwrap(destination.agentPromptPage)
            XCTAssertNotNil(AgentGuidance.guide(for: page ?? ""), destination.rawValue)
        }
        XCTAssertEqual(SidebarDestination.agentSkills.agentPromptPage, "agents")
        XCTAssertNotNil(AgentGuidance.guide(for: "settings"))
    }
}
