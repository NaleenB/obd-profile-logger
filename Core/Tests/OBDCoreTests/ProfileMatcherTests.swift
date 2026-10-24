import XCTest
@testable import OBDCore

final class ProfileMatcherTests: XCTestCase {

    /// Engine speed is required; coolant corroborates; the odometer is a
    /// plausibility check with no reference value.
    private func fixture(required: Bool = true, optionalFloor: Double? = nil) throws -> VehicleProfile {
        var coolant: [String: Any] = [
            "itemNumber": 7, "sameAsPID": "05", "tolerance": 5, "weight": 0.3
        ]
        if let optionalFloor { coolant["minimumStandard"] = optionalFloor }
        let dictionary: [String: Any] = [
            "schemaVersion": 1,
            "id": "test-profile",
            "manufacturer": "Mitsubishi",
            "model": "Model",
            "year": 2020,
            "engine": "Engine",
            "notes": [],
            "service": ["readByLocalIdentifier": "21"],
            "blocks": [],
            "identity": [
                "probeLIDs": ["01", "02", "03"],
                "discriminators": [
                    ["itemNumber": 2, "sameAsPID": "0C", "tolerance": 50,
                     "weight": 0.5, "required": required, "minimumStandard": 400],
                    coolant
                ],
                "plausibility": [
                    ["itemNumber": 145, "min": 100, "max": 2_000_000, "weight": 0.2]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(VehicleProfile.self, from: data)
    }

    private let standard: [UInt8: Double] = [0x0C: 650, 0x05: 59]

    func testEngineSpeedAgreementIsEnough() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 648],
            standard: standard)
        XCTAssertTrue(assessment.convincing)
        XCTAssertEqual(assessment.score, 0.5, accuracy: 0.001)
        XCTAssertFalse(assessment.contradicted)
    }

    func testEverythingAgreeingScoresFullMarks() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 650, 7: 59, 145: 80_360],
            standard: standard)
        XCTAssertTrue(assessment.convincing)
        XCTAssertEqual(assessment.score, 1.0, accuracy: 0.001)
    }

    /// The case that matters: decoding another model's block with these offsets
    /// yields a byte that has nothing to do with engine speed.
    func testDisagreeingEngineSpeedIsRejected() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 3_450, 7: 59, 145: 80_360],
            standard: standard)
        XCTAssertFalse(assessment.convincing,
                       "coolant and odometer cannot rescue a wrong engine-speed field")
        XCTAssertTrue(assessment.contradicted)
    }

    func testCloseButNotExactEngineSpeedCounts() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(), manufacturer: [2: 700], standard: standard)
        XCTAssertTrue(assessment.convincing)
    }

    func testSlightlyOffEngineSpeedIsNotEnoughAndIsContradicted() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(), manufacturer: [2: 780], standard: standard)
        XCTAssertFalse(assessment.convincing)
        XCTAssertTrue(assessment.contradicted)
    }

    /// With the engine off every profile agrees on zero, so a comparison below
    /// the declared floor proves nothing.
    func testEngineOffMeansNoJudgement() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 0, 145: 80_360],
            standard: [0x0C: 0, 0x05: 20])
        XCTAssertFalse(assessment.convincing)
    }

    func testMissingReferenceCannotConvince() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 650],
            standard: [0x05: 59])
        XCTAssertFalse(assessment.convincing)
    }

    func testMissingManufacturerAnswerCannotConvince() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [7: 59],
            standard: standard)
        XCTAssertFalse(assessment.convincing)
    }

    func testImplausibleOdometerScoresNothingButDoesNotBreakAgreement() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 650, 145: 9_000_000],
            standard: standard)
        XCTAssertEqual(assessment.score, 0.5, accuracy: 0.001)
        XCTAssertTrue(assessment.convincing)
    }

    /// A corroborating value that cannot be read must not veto the required
    /// test. Coolant is optional: losing it costs its weight, nothing more.
    func testMissingOptionalReferenceDoesNotVetoAgreement() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(),
            manufacturer: [2: 650, 7: 59],
            standard: [0x0C: 650])
        XCTAssertTrue(assessment.convincing)
        XCTAssertEqual(assessment.score, 0.5, accuracy: 0.001)
    }

    /// The same applies when an optional discriminator declares a floor the
    /// reading does not reach.
    func testOptionalReferenceBelowItsFloorDoesNotVetoAgreement() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(optionalFloor: 80),
            manufacturer: [2: 650, 7: 20],
            standard: [0x0C: 650, 0x05: 20])
        XCTAssertTrue(assessment.convincing)
    }

    /// "No contradiction" and "no evidence to judge" are different states, and
    /// profile verification depends on being able to tell them apart.
    func testRequiredEvidenceNeedsBothSides() throws {
        let profile = try fixture()
        XCTAssertTrue(ProfileMatcher.hasRequiredEvidence(
            profile: profile, manufacturer: [2: 650], standard: [0x0C: 650]))
        XCTAssertFalse(ProfileMatcher.hasRequiredEvidence(
            profile: profile, manufacturer: [2: 650], standard: [0x0C: 0]),
            "engine off is not usable evidence")
        XCTAssertFalse(ProfileMatcher.hasRequiredEvidence(
            profile: profile, manufacturer: [:], standard: [0x0C: 650]))
        XCTAssertFalse(ProfileMatcher.hasRequiredEvidence(
            profile: profile, manufacturer: [2: 650], standard: [:]))
    }

    /// A profile with no identity block cannot be matched by live data at all.
    func testProfileWithoutIdentityNeverConvinces() throws {
        let dictionary: [String: Any] = [
            "schemaVersion": 1, "id": "plain", "manufacturer": "Mitsubishi",
            "model": "Model", "year": 2020, "engine": "Engine", "notes": [],
            "service": ["readByLocalIdentifier": "21"], "blocks": []
        ]
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        let profile = try JSONDecoder().decode(VehicleProfile.self, from: data)

        let assessment = ProfileMatcher.assess(
            profile: profile, manufacturer: [2: 650], standard: standard)
        XCTAssertFalse(assessment.convincing)
        XCTAssertEqual(assessment.score, 0)
    }

    /// A corroborating value alone must never select a profile: the required
    /// discriminator decides.
    func testNonRequiredAgreementIsNotEnough() throws {
        let assessment = ProfileMatcher.assess(
            profile: try fixture(), manufacturer: [7: 59], standard: standard)
        XCTAssertFalse(assessment.convincing)
    }
}
