import XCTest
@testable import OBDCore

final class ProfileResolverTests: XCTestCase {

    private func makeProfile(
        id: String,
        manufacturer: String = "Mitsubishi",
        calibrationIDs: [String]? = nil,
        vinPrefixes: [String]? = nil
    ) throws -> VehicleProfile {
        var dictionary: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "manufacturer": manufacturer,
            "model": "Model",
            "year": 2020,
            "engine": "Engine",
            "notes": [],
            "service": ["readByLocalIdentifier": "21"],
            "blocks": []
        ]
        dictionary["calibrationIDs"] = calibrationIDs
        dictionary["vinPrefixes"] = vinPrefixes
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(VehicleProfile.self, from: data)
    }

    private func convincing(_ id: String, score: Double = 0.8) -> ProfileAssessment {
        ProfileAssessment(profileID: id, score: score, convincing: true,
                          contradicted: false, evidence: [])
    }

    private func unconvincing(_ id: String) -> ProfileAssessment {
        ProfileAssessment(profileID: id, score: 0.1, convincing: false,
                          contradicted: true, evidence: [])
    }

    func testCalibrationMatchWins() throws {
        let profiles = [
            try makeProfile(id: "a", calibrationIDs: ["1860C97201"], vinPrefixes: ["JMFXLGF6W"]),
            try makeProfile(id: "b", calibrationIDs: ["OTHER"], vinPrefixes: ["JMFXLGF6W"])
        ]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651", calibrationID: "1860C97201"),
            manufacturerAvailable: true)
        XCTAssertEqual(result.profileID, "a")
        XCTAssertEqual(result.method, .calibration)
    }

    /// Calibration is unreadable, so the VIN prefix decides.
    func testVinIsUsedWhenCalibrationIsMissing() throws {
        let profiles = [try makeProfile(id: "a", vinPrefixes: ["JMFXLGF6W"])]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651"),
            manufacturerAvailable: true)
        XCTAssertEqual(result.profileID, "a")
        XCTAssertEqual(result.method, .vin)
    }

    /// A calibration ID that was read and matched nothing is evidence against
    /// these offsets, not a missing identity. A VIN hit alone must not override
    /// it.
    func testUnknownCalibrationBlocksVinOnlySelection() throws {
        let profiles = [try makeProfile(id: "a", calibrationIDs: ["KNOWN"],
                                        vinPrefixes: ["JMFXLGF6W"])]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651", calibrationID: "OTHER"),
            manufacturerAvailable: true)
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.method, .none)
        XCTAssertTrue(result.reason.lowercased().contains("calibration"), result.reason)
    }

    /// With the calibration unrecognised, live data may still prove the layout.
    func testUnknownCalibrationWithMatchingVinNeedsAgreement() throws {
        let profiles = [try makeProfile(id: "a", calibrationIDs: ["KNOWN"],
                                        vinPrefixes: ["JMFXLGF6W"])]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651", calibrationID: "OTHER"),
            manufacturerAvailable: true,
            assessments: [convincing("a")])
        XCTAssertEqual(result.profileID, "a")
        XCTAssertEqual(result.method, .vin)
    }

    /// An unreadable calibration leaves the VIN route open.
    func testMissingCalibrationUsesVinDirectly() throws {
        let profiles = [try makeProfile(id: "a", calibrationIDs: ["KNOWN"],
                                        vinPrefixes: ["JMFXLGF6W"])]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651"),
            manufacturerAvailable: true)
        XCTAssertEqual(result.profileID, "a")
        XCTAssertEqual(result.method, .vin)
    }

    /// The longest matching prefix is more specific than a shorter one.
    func testLongestVinPrefixWins() throws {
        let profiles = [
            try makeProfile(id: "short", vinPrefixes: ["JMF"]),
            try makeProfile(id: "long", vinPrefixes: ["JMFXLGF6W"])
        ]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651"),
            manufacturerAvailable: true)
        XCTAssertEqual(result.profileID, "long")
        XCTAssertEqual(result.method, .vin)
    }

    /// Two profiles share a prefix and nothing separates them: say so rather
    /// than picking one.
    func testAmbiguousVinIsReported() throws {
        let profiles = [
            try makeProfile(id: "a", vinPrefixes: ["JMFXLGF6W"]),
            try makeProfile(id: "b", vinPrefixes: ["JMFXLGF6W"])
        ]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(vin: "JMFXLGF6WHZ000651"),
            manufacturerAvailable: true)
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.ambiguousIDs, ["a", "b"])
    }

    func testLiveAgreementIsUsedWithNoIdentity() throws {
        let profiles = [try makeProfile(id: "a")]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(),
            manufacturerAvailable: true,
            assessments: [convincing("a")])
        XCTAssertEqual(result.profileID, "a")
        XCTAssertEqual(result.method, .agreement)
    }

    /// Answering the manufacturer service is not evidence that the offsets apply.
    func testManufacturerServiceAloneIsNotEnough() throws {
        let profiles = [try makeProfile(id: "a")]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(),
            manufacturerAvailable: true,
            assessments: [unconvincing("a")])
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.method, .none)
    }

    func testNoManufacturerServiceResolvesNothing() throws {
        let profiles = [try makeProfile(id: "a", calibrationIDs: ["X"])]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(calibrationID: "X"),
            manufacturerAvailable: false)
        XCTAssertEqual(result.profileID, "a",
                       "calibration still identifies the car without service 0x21")
    }

    /// Two profiles declaring the same calibration are separated by live data
    /// when it is available.
    func testAmbiguousCalibrationIsBrokenByAgreement() throws {
        let profiles = [
            try makeProfile(id: "a", calibrationIDs: ["1"]),
            try makeProfile(id: "b", calibrationIDs: ["1"])
        ]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(calibrationID: "1"),
            manufacturerAvailable: true,
            assessments: [unconvincing("a"), convincing("b", score: 0.9)])
        XCTAssertEqual(result.profileID, "b")
        XCTAssertEqual(result.method, .calibration)
    }

    func testAmbiguousCalibrationWithoutAgreementIsReported() throws {
        let profiles = [
            try makeProfile(id: "a", calibrationIDs: ["1"]),
            try makeProfile(id: "b", calibrationIDs: ["1"])
        ]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(calibrationID: "1"),
            manufacturerAvailable: true)
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.ambiguousIDs, ["a", "b"])
    }

    /// A tie on live data must not pick the first candidate.
    func testEquallyConvincingProfilesAreAmbiguous() throws {
        let profiles = [try makeProfile(id: "a"), try makeProfile(id: "b")]
        let result = ProfileResolver.resolve(
            candidates: profiles,
            identity: VehicleIdentity(),
            manufacturerAvailable: true,
            assessments: [convincing("a", score: 0.8), convincing("b", score: 0.8)])
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.ambiguousIDs, ["a", "b"])
    }

    func testGenericProfileIsNeverAResolution() throws {
        let generic = try makeProfile(id: "generic", manufacturer: "Generic")
        let result = ProfileResolver.resolve(
            candidates: [generic],
            identity: VehicleIdentity(),
            manufacturerAvailable: true,
            assessments: [convincing("generic")])
        XCTAssertNil(result.profileID)
    }

    func testNoProfilesYieldsNothing() {
        let result = ProfileResolver.resolve(candidates: [], manufacturerAvailable: true)
        XCTAssertNil(result.profileID)
        XCTAssertEqual(result.method, .none)
    }
}
