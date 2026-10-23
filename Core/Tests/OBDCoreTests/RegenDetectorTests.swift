import XCTest
@testable import OBDCore

final class RegenDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testIdleTemperatureDoesNotTrigger() {
        var detector = RegenDetector()
        XCTAssertNil(detector.ingest(tempC: 180, at: at(0)))
        XCTAssertNil(detector.ingest(tempC: 300, at: at(5)))
        XCTAssertFalse(detector.isActive)
    }

    func testRisingAboveThresholdStartsOnce() {
        var detector = RegenDetector()
        XCTAssertNil(detector.ingest(tempC: 400, at: at(0)))
        XCTAssertEqual(detector.ingest(tempC: 470, at: at(10)), .started(tempC: 470))
        XCTAssertTrue(detector.isActive)
        // Still active: no repeated start events.
        XCTAssertNil(detector.ingest(tempC: 520, at: at(60)))
        XCTAssertNil(detector.ingest(tempC: 600, at: at(120)))
    }

    func testHysteresisKeepsEventOpenAboveEndThreshold() {
        var detector = RegenDetector()
        _ = detector.ingest(tempC: 500, at: at(0))
        // Drops but stays above the end threshold: still regenerating.
        XCTAssertNil(detector.ingest(tempC: 350, at: at(30)))
        XCTAssertTrue(detector.isActive)
    }

    func testEndsAfterDwellBelowThreshold() {
        var detector = RegenDetector()
        _ = detector.ingest(tempC: 500, at: at(0))
        _ = detector.ingest(tempC: 600, at: at(60))
        XCTAssertNil(detector.ingest(tempC: 250, at: at(100)))
        // Not long enough yet.
        XCTAssertNil(detector.ingest(tempC: 250, at: at(105)))

        let end = detector.ingest(tempC: 240, at: at(115))
        guard case .ended(let duration, let peak)? = end else {
            return XCTFail("expected ended, got \(String(describing: end))")
        }
        XCTAssertEqual(duration, 115, accuracy: 0.001)
        XCTAssertEqual(peak, 600, accuracy: 0.001)
        XCTAssertFalse(detector.isActive)
    }

    func testBriefDipDoesNotCloseTheEvent() {
        var detector = RegenDetector()
        _ = detector.ingest(tempC: 500, at: at(0))
        XCTAssertNil(detector.ingest(tempC: 200, at: at(10)))
        // Back above before the dwell elapsed.
        XCTAssertNil(detector.ingest(tempC: 550, at: at(15)))
        XCTAssertNil(detector.ingest(tempC: 200, at: at(20)))
        XCTAssertTrue(detector.isActive)
    }

    /// A regeneration that is still running when the session ends must be closed
    /// rather than lost.
    func testFinishClosesAnOpenEvent() {
        var detector = RegenDetector()
        _ = detector.ingest(tempC: 500, at: at(0))
        let end = detector.finish(at: at(300))
        guard case .ended(let duration, _)? = end else {
            return XCTFail("expected ended")
        }
        XCTAssertEqual(duration, 300, accuracy: 0.001)
        XCTAssertFalse(detector.isActive)
    }

    func testFinishWithNoEventDoesNothing() {
        var detector = RegenDetector()
        _ = detector.ingest(tempC: 200, at: at(0))
        XCTAssertNil(detector.finish(at: at(60)))
    }
}
