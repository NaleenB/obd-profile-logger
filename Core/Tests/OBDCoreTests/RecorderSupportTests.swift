import XCTest
@testable import OBDCore

final class PIDScalingTests: XCTestCase {

    /// Raw 0x0D2C = 3372. PID 0x23 is 10 kPa per bit, so 33 720 kPa = 337.2 bar.
    func testRailPressureConvertsToBar() {
        XCTAssertEqual(PIDScaling.railPressureBar(raw: 0x0D2C), 337.2, accuracy: 0.001)
        XCTAssertEqual(PIDScaling.railPressureBar(a: 0x0D, b: 0x2C), 337.2, accuracy: 0.001)
    }

    func testRailPressureKiloPascals() {
        XCTAssertEqual(PIDScaling.railPressureKPa(raw: 3372), 33_720, accuracy: 0.001)
    }

    func testZeroIsZero() {
        XCTAssertEqual(PIDScaling.railPressureBar(raw: 0), 0)
    }

    /// The previous implementation returned the raw value, understating pressure
    /// by a factor of ten.
    func testNotRawValue() {
        XCTAssertNotEqual(PIDScaling.railPressureBar(raw: 3372), 3372)
    }
}

final class DTCScannerTests: XCTestCase {

    /// Drives the scanner with a scripted sequence of replies.
    private func scan(
        targets: [DTCScanner.Target] = DTCScanner.defaultTargets,
        replies: [String?]
    ) -> DTCScanner {
        var scanner = DTCScanner(targets: targets)
        var index = 0
        while case .command = scanner.next() {
            scanner.ingest(responseHex: index < replies.count ? replies[index] : nil)
            index += 1
        }
        return scanner
    }

    /// Command order is ATSH, 0101, 03, 07, 0A per module.
    private let completeModule: [String?] = ["OK", "4101004C8000", "430301", "4700", "4A00"]

    func testCommandSequencePerModule() {
        var scanner = DTCScanner(targets: [.init(module: "ECM", header: "7E0")])
        var commands: [String] = []
        while case .command(let command) = scanner.next() {
            commands.append(command)
            scanner.ingest(responseHex: "OK")
        }
        XCTAssertEqual(commands, ["ATSH7E0", "0101", "03", "07", "0A"])
        XCTAssertTrue(scanner.isFinished)
    }

    func testBothModulesKeepTheirOwnCodes() {
        let replies: [String?] = [
            "OK", "4101004C8000", "430301", "4700", "4A00",     // ECM: P0301
            "OK", "410100000000", "430700", "4700", "4A00"      // TCM: P0700
        ]
        let scanner = scan(replies: replies)
        XCTAssertTrue(scanner.diagnostics.isComplete)
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0301"])
        XCTAssertEqual(scanner.diagnostics.codes(for: "TCM"), ["P0700"])
        XCTAssertFalse(scanner.diagnostics.codes(for: "ECM").contains("P0700"))
    }

    func testSilentModuleMakesScanIncomplete() {
        let replies: [String?] = completeModule + ["OK", nil, nil, nil, nil]
        let scanner = scan(replies: replies)
        XCTAssertFalse(scanner.diagnostics.isComplete)
        XCTAssertEqual(scanner.diagnostics.modulesIncomplete, ["TCM"])
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0301"])
    }

    /// "No codes" and "no answer" must not look the same.
    func testEmptyIsDistinguishedFromNoReply() {
        let replies: [String?] = ["OK", "410100000000", "4300", nil, nil]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "empty")
        XCTAssertEqual(scanner.outcomeDetails["ECM.pending"], "no_reply")
        XCTAssertEqual(scanner.outcomeDetails["ECM.permanent"], "no_reply")
        XCTAssertFalse(scanner.diagnostics.isComplete)
    }

    func testRejectedServiceIsNotTreatedAsEmpty() {
        let replies: [String?] = ["OK", "4101004C8000", "7F0311", "4700", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "rejected")
        XCTAssertFalse(scanner.diagnostics.isComplete)
    }

    func testMalformedReplyIsNotTreatedAsNoCodes() {
        let replies: [String?] = ["OK", "4101004C8000", "43", "4700", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "malformed")
    }

    func testPendingCodeIsReported() {
        let replies: [String?] = ["OK", "410100040000", "4300", "470047", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0047"])
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "empty")
        XCTAssertEqual(scanner.outcomeDetails["ECM.pending"], "ok")
    }
}
