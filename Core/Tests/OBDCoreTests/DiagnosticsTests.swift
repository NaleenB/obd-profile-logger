import XCTest
@testable import OBDCore

final class DiagnosticsTests: XCTestCase {

    // MARK: Decoding

    func testEmptyPayloadIsNoCodes() {
        // "4300" with the service byte removed.
        XCTAssertEqual(DTCDecoder.codes(fromHex: "00"), [])
    }

    func testCodesDecode() {
        XCTAssertEqual(DTCDecoder.codes(fromHex: "0301"), ["P0301"])
    }

    func testGarbageIsUndecodableNotEmpty() {
        XCTAssertNil(DTCDecoder.codes(fromHex: "ZZ"))
        XCTAssertNil(DTCDecoder.codes(fromHex: "030"))   // odd byte count
    }

    func testZeroPaddingIsSkipped() {
        XCTAssertEqual(DTCDecoder.codes(fromHex: "03010000"), ["P0301"])
    }

    // MARK: Aggregation across modules

    private func complete(_ module: String, _ header: String, _ codes: [String]) -> ModuleDiagnostics {
        ModuleDiagnostics(
            module: module, header: header,
            milOn: !codes.isEmpty, reportedDTCs: codes.count,
            stored: codes, pending: [], permanent: []
        )
    }

    func testModulesKeepTheirOwnCodes() {
        let scan = VehicleDiagnostics(modules: [
            complete("ECM", "7E0", ["P0301"]),
            complete("TCM", "7E1", ["P0700"])
        ])
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.codes(for: "ECM"), ["P0301"])
        XCTAssertEqual(scan.codes(for: "TCM"), ["P0700"])
        XCTAssertFalse(scan.codes(for: "ECM").contains("P0700"))
        XCTAssertEqual(scan.codesByModule["TCM"], ["P0700"])
        XCTAssertEqual(scan.headline, "2 code(s) across 2 modules")
    }

    func testOneModuleMissingMakesScanIncomplete() {
        let scan = VehicleDiagnostics(modules: [
            complete("ECM", "7E0", ["P0301"]),
            ModuleDiagnostics(module: "TCM", header: "7E1", milOn: nil,
                              reportedDTCs: nil, stored: nil, pending: nil, permanent: nil)
        ])
        XCTAssertFalse(scan.isComplete)
        XCTAssertEqual(scan.modulesIncomplete, ["TCM"])
        XCTAssertTrue(scan.headline.contains("Incomplete"))
        // The module that did answer is still reported honestly.
        XCTAssertEqual(scan.codes(for: "ECM"), ["P0301"])
    }

    func testAnsweredButEmptyIsNotIncomplete() {
        let scan = VehicleDiagnostics(modules: [
            complete("ECM", "7E0", []),
            complete("TCM", "7E1", [])
        ])
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.headline, "No codes in any module")
    }

    func testEmptyScanIsIncomplete() {
        XCTAssertFalse(VehicleDiagnostics(modules: []).isComplete)
    }

    func testPendingOnlyCodeIsReported() {
        let module = ModuleDiagnostics(
            module: "ECM", header: "7E0", milOn: false, reportedDTCs: 0,
            stored: [], pending: ["P0047"], permanent: []
        )
        XCTAssertTrue(module.isComplete)
        XCTAssertEqual(module.allCodes, ["P0047"])
    }
}
