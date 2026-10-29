import XCTest
import OBDCore
@testable import OBDLogger_macOS

@MainActor
final class LiveModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ProfileOverride")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ProfileOverride")
        super.tearDown()
    }

    /// Connecting after a previous car resolved must start from generic. The
    /// new car has not proved anything yet, and its manufacturer offsets are not
    /// the previous profile's.
    func testNewSessionDropsAResolvedProfileAndStaleDiagnostics() {
        let model = LiveModel()
        model.apply(ProfileResolver.Resolution(
            profileID: "mitsubishi-outlander-2016-4n14",
            method: .calibration,
            reason: "test"))
        model.completeScan(
            VehicleDiagnostics(modules: [
                ModuleDiagnostics(module: "ECM", header: "7E0", stored: ["P0300"])
            ]),
            outcomes: [:])

        XCTAssertEqual(model.profileID, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(model.profileMatchMethod, ProfileResolver.Method.calibration.rawValue)
        XCTAssertNotNil(model.diagnostics)

        model.resetForNewSession()

        XCTAssertEqual(model.profileID, ProfileCatalog.genericID)
        XCTAssertEqual(model.profile?.id, ProfileCatalog.genericID)
        XCTAssertEqual(model.profileMatchMethod, ProfileResolver.Method.none.rawValue)
        XCTAssertNil(model.diagnostics)
        XCTAssertNil(model.diagnosticsAt)
    }

    /// The development override is a deliberate process-level choice and must
    /// survive a new connection, unlike a profile a previous car proved.
    func testNewSessionPreservesTheDevelopmentOverride() {
        UserDefaults.standard.set("mitsubishi-outlander-2016-4n14", forKey: "ProfileOverride")

        let model = LiveModel()
        XCTAssertEqual(model.profileID, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(model.profileMatchMethod, ProfileResolver.Method.override.rawValue)

        model.resetForNewSession()

        XCTAssertEqual(model.profileID, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(model.profileMatchMethod, ProfileResolver.Method.override.rawValue)
    }

    /// A notice from the previous session ("saved with problems") must not
    /// describe the new connection while it is still starting.
    func testNewSessionClearsThePreviousNotice() {
        let model = LiveModel()
        model.notice = "Session saved with problems: test"

        model.resetForNewSession()

        XCTAssertNil(model.notice)
    }

    /// A rejected pin leaves `ATDPN` answering before auto-detection has run.
    /// The header is derived from that answer, so the session must say which
    /// protocol was reported and which header it actually addressed — that is
    /// the difference between a car refusing `0x21` and the request never
    /// reaching the ECM.
    func testRejectedPinIsRecordedWithTheHeaderItProduced() {
        let detected = "A0"
        let header = OBDProtocol.engineHeader(
            profileHeader: "7E0", protocolIdentifier: detected)
        XCTAssertEqual(header, "7DF", "A non-CAN answer must not be handed 7E0")

        let details = LiveModel.ProtocolDiagnostics(
            requested: "6",
            accepted: false,
            fellBackToAuto: true,
            detected: detected,
            header: header).details

        XCTAssertEqual(details["protocolRequested"], "6")
        XCTAssertEqual(details["protocolAccepted"], "false")
        XCTAssertEqual(details["protocolFallback"], "ATSP0")
        XCTAssertEqual(details["protocolDetected"], "A0")
        XCTAssertEqual(details["requestHeader"], "7DF")
    }

    /// The healthy path: the pin was accepted, so the engine module is
    /// addressed directly and `0x21` can be answered.
    func testAcceptedPinIsRecordedWithTheEngineHeader() {
        let detected = "A6"
        let header = OBDProtocol.engineHeader(
            profileHeader: "7E0", protocolIdentifier: detected)

        let details = LiveModel.ProtocolDiagnostics(
            requested: "6",
            accepted: true,
            fellBackToAuto: false,
            detected: detected,
            header: header).details

        XCTAssertEqual(details["protocolAccepted"], "true")
        XCTAssertEqual(details["protocolFallback"], "none")
        XCTAssertEqual(details["requestHeader"], "7E0")
    }

    /// With no pin there is nothing to accept or reject, and saying "false"
    /// would read as a failure.
    func testNoPinnedProtocolIsNotReportedAsRejected() {
        let details = LiveModel.ProtocolDiagnostics(
            requested: nil,
            accepted: false,
            fellBackToAuto: false,
            detected: nil,
            header: "7DF").details

        XCTAssertEqual(details["protocolRequested"], "auto")
        XCTAssertEqual(details["protocolAccepted"], "not_requested")
        XCTAssertEqual(details["protocolFallback"], "none")
        XCTAssertEqual(details["protocolDetected"], "")
    }
}
