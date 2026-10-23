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
        while case .request = scanner.next() {
            scanner.ingest(responseHex: index < replies.count ? replies[index] : nil)
            index += 1
        }
        return scanner
    }

    private func requests(_ scanner: inout DTCScanner) -> [DTCScanner.Request] {
        var out: [DTCScanner.Request] = []
        while case .request(let request) = scanner.next() {
            out.append(request)
            scanner.ingest(responseHex: "OK")
        }
        return out
    }

    /// Replies for one complete module: monitor, stored, pending, permanent.
    private let completeModule: [String?] = ["4101004C8000", "430301", "4700", "4A00"]

    func testCommandSequenceCarriesHeaderOnEveryRequest() {
        var scanner = DTCScanner(targets: [.init(module: "ECM", header: "7E0")])
        let out = requests(&scanner)
        XCTAssertEqual(out.map(\.command), ["0101", "03", "07", "0A"])
        XCTAssertTrue(out.allSatisfy { $0.header == "7E0" })
        XCTAssertTrue(out.allSatisfy { $0.module == "ECM" })
    }

    /// The header is part of the request, so interleaving other traffic between
    /// steps cannot cause a query to go to the wrong module.
    func testHeaderIsIndependentOfCallerStateBetweenSteps() {
        var scanner = DTCScanner()
        var seen: [(String, String)] = []
        var interleavedHeader = "7DF"

        while case .request(let request) = scanner.next() {
            // Simulate other traffic resetting addressing before each step.
            interleavedHeader = "7DF"
            // The caller must select the request's header immediately before sending.
            interleavedHeader = request.header
            seen.append((interleavedHeader, request.command))
            scanner.ingest(responseHex: nil)
        }

        XCTAssertEqual(seen.map { $0.0 }, ["7E0", "7E0", "7E0", "7E0", "7E1", "7E1", "7E1", "7E1"])
        XCTAssertEqual(seen.map { $0.1 }, ["0101", "03", "07", "0A", "0101", "03", "07", "0A"])
    }

    func testBothModulesKeepTheirOwnCodes() {
        let replies: [String?] = completeModule + ["410100000000", "430700", "4700", "4A00"]
        let scanner = scan(replies: replies)
        XCTAssertTrue(scanner.diagnostics.isComplete)
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0301"])
        XCTAssertEqual(scanner.diagnostics.codes(for: "TCM"), ["P0700"])
        XCTAssertFalse(scanner.diagnostics.codes(for: "ECM").contains("P0700"))
    }

    func testSilentModuleMakesScanIncomplete() {
        let scanner = scan(replies: completeModule + [nil, nil, nil, nil])
        XCTAssertFalse(scanner.diagnostics.isComplete)
        XCTAssertEqual(scanner.diagnostics.modulesIncomplete, ["TCM"])
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0301"])
    }

    func testEmptyIsDistinguishedFromNoReply() {
        let replies: [String?] = ["410100000000", "4300", nil, nil]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "empty")
        XCTAssertEqual(scanner.outcomeDetails["ECM.pending"], "no_reply")
        XCTAssertEqual(scanner.outcomeDetails["ECM.permanent"], "no_reply")
        XCTAssertFalse(scanner.diagnostics.isComplete)
    }

    func testRejectedServiceIsNotTreatedAsEmpty() {
        let replies: [String?] = ["4101004C8000", "7F0311", "4700", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "rejected")
        XCTAssertFalse(scanner.diagnostics.isComplete)
    }

    func testMalformedReplyIsNotTreatedAsNoCodes() {
        let replies: [String?] = ["4101004C8000", "43", "4700", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "malformed")
    }

    func testPendingCodeIsReported() {
        let replies: [String?] = ["410100040000", "4300", "470047", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0047"])
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "empty")
        XCTAssertEqual(scanner.outcomeDetails["ECM.pending"], "ok")
    }
}

final class DTCSnapshotTests: XCTestCase {

    private func diagnostics(mil: Bool?, stored: [String]?, complete: Bool) -> VehicleDiagnostics {
        VehicleDiagnostics(modules: [
            ModuleDiagnostics(
                module: "ECM", header: "7E0",
                milOn: mil, reportedDTCs: stored?.count,
                stored: stored,
                pending: complete ? [] : nil,
                permanent: complete ? [] : nil
            )
        ])
    }

    func testIdenticalScansProduceIdenticalSignatures() {
        let a = diagnostics(mil: false, stored: ["P0301"], complete: true)
        let b = diagnostics(mil: false, stored: ["P0301"], complete: true)
        let outcomes = ["ECM.stored": "ok"]
        XCTAssertEqual(
            DTCSnapshot.signature(a, outcomes: outcomes),
            DTCSnapshot.signature(b, outcomes: outcomes)
        )
    }

    func testOutcomeChangeProducesNewSignature() {
        let d = diagnostics(mil: false, stored: [], complete: true)
        let first = DTCSnapshot.signature(d, outcomes: ["ECM.stored": "empty"])
        let second = DTCSnapshot.signature(d, outcomes: ["ECM.stored": "no_reply"])
        XCTAssertNotEqual(first, second, "an outcome change must not be swallowed")
    }

    func testMilChangeProducesNewSignature() {
        let a = diagnostics(mil: false, stored: [], complete: true)
        let b = diagnostics(mil: true, stored: [], complete: true)
        XCTAssertNotEqual(
            DTCSnapshot.signature(a, outcomes: [:]),
            DTCSnapshot.signature(b, outcomes: [:])
        )
    }

    func testCompletenessChangeProducesNewSignature() {
        let a = diagnostics(mil: false, stored: [], complete: true)
        let b = diagnostics(mil: false, stored: [], complete: false)
        XCTAssertNotEqual(
            DTCSnapshot.signature(a, outcomes: [:]),
            DTCSnapshot.signature(b, outcomes: [:])
        )
    }
}
