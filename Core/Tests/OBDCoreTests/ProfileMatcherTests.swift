import XCTest
@testable import OBDCore

final class ProfileMatcherTests: XCTestCase {

    func testAgreementOnEverythingIsConvincing() {
        let evidence = ProfileEvidence(
            manufacturerRPM: 650, standardRPM: 648,
            manufacturerCoolant: 59, standardCoolant: 59,
            odometerKm: 80_360
        )
        XCTAssertTrue(ProfileMatcher.isConvincing(evidence))
        XCTAssertEqual(ProfileMatcher.score(evidence), 1.0, accuracy: 0.001)
    }

    /// The case that matters: decoding another model's block with these offsets
    /// yields a byte that has nothing to do with engine speed.
    func testDisagreeingRPMIsRejected() {
        let evidence = ProfileEvidence(
            manufacturerRPM: 3_450, standardRPM: 650,
            manufacturerCoolant: 59, standardCoolant: 59,
            odometerKm: 80_360
        )
        XCTAssertFalse(ProfileMatcher.isConvincing(evidence),
                       "coolant and odometer cannot rescue a wrong engine-speed field")
    }

    func testCloseButNotExactRPMStillCounts() {
        let evidence = ProfileEvidence(manufacturerRPM: 700, standardRPM: 650)
        XCTAssertTrue(ProfileMatcher.isConvincing(evidence))
    }

    func testSlightlyOffRPMIsNotEnough() {
        let evidence = ProfileEvidence(manufacturerRPM: 780, standardRPM: 650)
        XCTAssertFalse(ProfileMatcher.isConvincing(evidence))
    }

    func testMissingStandardRPMCannotConvince() {
        XCTAssertFalse(ProfileMatcher.isConvincing(ProfileEvidence(manufacturerRPM: 650)))
    }

    func testEngineOffMeansNoJudgement() {
        let evidence = ProfileEvidence(
            manufacturerRPM: 0, standardRPM: 0, odometerKm: 80_360
        )
        XCTAssertFalse(ProfileMatcher.isConvincing(evidence),
                       "with the engine off every profile agrees on zero")
    }

    func testImplausibleOdometerScoresNothing() {
        let evidence = ProfileEvidence(odometerKm: 9_000_000)
        XCTAssertEqual(ProfileMatcher.score(evidence), 0, accuracy: 0.001)
    }
}
