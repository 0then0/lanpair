import XCTest

final class RunnerTests: XCTestCase {
    func testLocalNetworkConfiguration() {
        let bundle = Bundle.main
        let services = bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        XCTAssertEqual(services, ["_lanpair._tcp"])
        for key in ["NSLocalNetworkUsageDescription", "NSCameraUsageDescription"] {
            let description = bundle.object(forInfoDictionaryKey: key) as? String
            XCTAssertFalse(description?.isEmpty ?? true, "Missing usage description: \(key)")
        }
    }
}
