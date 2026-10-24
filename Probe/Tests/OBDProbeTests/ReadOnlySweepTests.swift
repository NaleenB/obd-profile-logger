import XCTest
@testable import OBDProbe

final class ReadOnlySweepTests: XCTestCase {

    func testOnlyReadServicesAreAllowed() {
        XCTAssertEqual(Probe.readOnlySweepServices, [0x21, 0x22, 0x1A])
        XCTAssertFalse(Probe.readOnlySweepServices.contains(0x2E))
        XCTAssertFalse(Probe.readOnlySweepServices.contains(0x2F))
        XCTAssertFalse(Probe.readOnlySweepServices.contains(0x31))
    }
}
