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
}
