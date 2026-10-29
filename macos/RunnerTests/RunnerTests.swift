import XCTest

final class RunnerTests: XCTestCase {
    func testLocalNetworkConfiguration() {
        let bundle = Bundle.main
        let services = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        XCTAssertEqual(services, ["_lanpair._tcp"])
        let description = bundle.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        XCTAssertFalse(description?.isEmpty ?? true, "Missing local-network usage description")
    }
}
