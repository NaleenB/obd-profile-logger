import XCTest
@testable import OBDCore

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

    /// A header that the adapter refuses must abort the query, not fall through
    /// to whichever module was addressed last.
    func testHeaderFailureSkipsQueryAndIsRecorded() {
        var scanner = DTCScanner(targets: [.init(module: "TCM", header: "7E1")])
        var commands: [String] = []

        while case .request(let request) = scanner.next() {
            commands.append(request.command)
            // Simulate ATSH7E1 not being acknowledged: no query is sent.
            scanner.ingestHeaderFailure()
        }

        XCTAssertEqual(commands, ["0101", "03", "07", "0A"])
        XCTAssertEqual(scanner.outcomeDetails["TCM.monitor"], "header_error")
        XCTAssertEqual(scanner.outcomeDetails["TCM.stored"], "header_error")
        XCTAssertFalse(scanner.diagnostics.isComplete)
        XCTAssertEqual(scanner.diagnostics.codes(for: "TCM"), [])
    }

    /// A header failure for one module must not disturb the other module.
    func testHeaderFailureIsPerModule() {
        var scanner = DTCScanner()
        var index = 0

        while case .request(let request) = scanner.next() {
            if request.header == "7E1" {
                scanner.ingestHeaderFailure()
            } else {
                let replies = ["4101004C8000", "430301", "4700", "4A00"]
                scanner.ingest(responseHex: index < replies.count ? replies[index] : nil)
                index += 1
            }
        }

        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0301"])
        XCTAssertEqual(scanner.diagnostics.codes(for: "TCM"), [])
        XCTAssertEqual(scanner.diagnostics.modulesIncomplete, ["TCM"])
        XCTAssertEqual(scanner.outcomeDetails["TCM.stored"], "header_error")
        XCTAssertNotEqual(scanner.outcomeDetails["ECM.stored"], "header_error")
    }

    func testPendingCodeIsReported() {
        let replies: [String?] = ["410100040000", "4300", "470047", "4A00"]
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")], replies: replies)
        XCTAssertEqual(scanner.diagnostics.codes(for: "ECM"), ["P0047"])
        XCTAssertEqual(scanner.outcomeDetails["ECM.stored"], "empty")
        XCTAssertEqual(scanner.outcomeDetails["ECM.pending"], "ok")
    }
    /// The monitor reply is four data bytes. Two bytes cannot express readiness,
    /// so a short reply must not be recorded as a usable monitor result.
    func testTruncatedMonitorReplyIsMalformedNotOK() {
        for reply in ["4101", "410100", "4101004C", "4101004C80"] {
            let scanner = scan(targets: [.init(module: "ECM", header: "7E0")],
                               replies: [reply, "4300", "4700", "4A00"])
            XCTAssertEqual(scanner.outcomeDetails["ECM.monitor"], "malformed", "reply \(reply)")
            XCTAssertNil(scanner.diagnostics.modules[0].milOn, "reply \(reply)")
            XCTAssertFalse(scanner.diagnostics.isComplete, "reply \(reply)")
        }
    }

    /// MIL and the ECU's reported count still decode from a full reply.
    func testMonitorReplyDecodesMilAndCount() {
        let scanner = scan(targets: [.init(module: "ECM", header: "7E0")],
                           replies: ["4101834C8000", "4300", "4700", "4A00"])
        XCTAssertEqual(scanner.diagnostics.modules[0].milOn, true)
        XCTAssertEqual(scanner.diagnostics.modules[0].reportedDTCs, 3)
    }
}

