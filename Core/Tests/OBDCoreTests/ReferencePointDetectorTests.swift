import XCTest
@testable import OBDCore

final class ReferencePointDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testSteadyWindowProducesAReference() {
        var detector = ReferencePointDetector()
        var reference: ReferencePointDetector.Reference?
        for i in 0...20 {
            if let emitted = detector.ingest(at: at(Double(i)), rpm: 2000, maf: 60, dp: 5.0) {
                reference = reference ?? emitted
            }
        }
        XCTAssertNotNil(reference)
        XCTAssertEqual(reference?.rpm, 2000)
        XCTAssertEqual(reference?.deltaPressureKPa ?? 0, 5.0, accuracy: 0.001)
    }

    /// A burst of fast samples must not qualify a two-second glimpse.
    func testFastBurstDoesNotQualify() {
        var detector = ReferencePointDetector()
        var emitted = 0
        for i in 0...8 {
            if detector.ingest(at: at(Double(i) * 0.25), rpm: 2000, maf: 60, dp: 5.0) != nil {
                emitted += 1
            }
        }
        XCTAssertEqual(emitted, 0, "2 s of data is not a 10 s steady window")
    }

    func testOutOfBandRpmRejectsTheWindow() {
        var detector = ReferencePointDetector()
        var emitted = 0
        for i in 0...20 {
            if detector.ingest(at: at(Double(i)), rpm: 2600, maf: 60, dp: 5.0) != nil { emitted += 1 }
        }
        XCTAssertEqual(emitted, 0)
    }

    func testOutOfBandAirflowRejectsTheWindow() {
        var detector = ReferencePointDetector()
        var emitted = 0
        for i in 0...20 {
            if detector.ingest(at: at(Double(i)), rpm: 2000, maf: 20, dp: 5.0) != nil { emitted += 1 }
        }
        XCTAssertEqual(emitted, 0)
    }

    /// A single excursion inside the window disqualifies it: the point must be
    /// genuinely steady or it is not comparable.
    func testBriefExcursionDisqualifiesTheWindow() {
        var detector = ReferencePointDetector()
        var duringExcursion = 0

        // While the excursion is still inside the window, nothing qualifies.
        for i in 0...12 {
            let rpm: Double = (i == 7) ? 2400 : 2000
            if detector.ingest(at: at(Double(i)), rpm: rpm, maf: 60, dp: 5.0) != nil {
                duringExcursion += 1
            }
        }
        XCTAssertEqual(duringExcursion, 0, "an excursion inside the window disqualifies it")

        // Once it ages out, the window is genuinely steady again.
        var afterExcursion = 0
        for i in 13...22 {
            if detector.ingest(at: at(Double(i)), rpm: 2000, maf: 60, dp: 5.0) != nil {
                afterExcursion += 1
            }
        }
        XCTAssertGreaterThanOrEqual(afterExcursion, 1)
    }

    func testCooldownPreventsRepeats() {
        var detector = ReferencePointDetector(cooldown: 60)
        var emitted = 0
        for i in 0...80 {
            if detector.ingest(at: at(Double(i)), rpm: 2000, maf: 60, dp: 5.0) != nil {
                emitted += 1
            }
        }
        // 81 seconds of steady conditions with a 60 s cooldown: one, maybe two.
        XCTAssertGreaterThanOrEqual(emitted, 1)
        XCTAssertLessThanOrEqual(emitted, 2)
    }

    func testMissingSignalsResetTheWindow() {
        var detector = ReferencePointDetector()
        var emitted = 0
        for i in 0...6 {
            if detector.ingest(at: at(Double(i)), rpm: 2000, maf: 60, dp: 5.0) != nil { emitted += 1 }
        }
        _ = detector.ingest(at: at(7), rpm: nil, maf: nil, dp: 5.0)
        for i in 8...14 {
            if detector.ingest(at: at(Double(i)), rpm: 2000, maf: 60, dp: 5.0) != nil { emitted += 1 }
        }
        XCTAssertEqual(emitted, 0, "7 s after a dropout is not a full window")
    }
}
