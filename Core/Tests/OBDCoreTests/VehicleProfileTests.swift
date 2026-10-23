import XCTest
@testable import OBDCore

final class VehicleProfileTests: XCTestCase {

    /// The profile that actually ships, not a hand-made fixture.
    private func shippedProfile() throws -> VehicleProfile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OBDCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("profiles/mitsubishi/outlander-2016-4n14.json")
        return try VehicleProfileLoader.load(from: url)
    }

    func testShippedProfileLoads() throws {
        let profile = try shippedProfile()
        XCTAssertEqual(profile.id, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(profile.manufacturer, "Mitsubishi")
        XCTAssertEqual(profile.service.readByLocalIdentifier, "21")
        XCTAssertNil(profile.service.readByIdentifier, "0x22 is not implemented on this ECU")
        XCTAssertGreaterThan(profile.blocks.count, 50)
    }

    func testEveryBlockHasAParsableIdentifier() throws {
        let profile = try shippedProfile()
        for block in profile.blocks {
            XCTAssertNotNil(block.lidValue, "lid \(block.lid) is not a hex byte")
        }
        XCTAssertEqual(profile.localIdentifiers.count, profile.blocks.count)
    }

    /// The captured frame from the car: 2.6 g/L soot by summation at byte 4.
    func testDecodesCapturedSootFrameUsingShippedProfile() throws {
        let profile = try shippedProfile()
        let frame = try XCTUnwrap(MUT21Frame(hex: "6111141F34061D"))
        let decoded = profile.decode(frame)

        let soot = try XCTUnwrap(decoded.first { $0.itemNumber == 155 })
        XCTAssertEqual(soot.value, 2.6, accuracy: 0.001)
        XCTAssertEqual(soot.unit, "g/L")

        let pressure = try XCTUnwrap(decoded.first { $0.itemNumber == 156 })
        XCTAssertEqual(pressure.value, 0.3, accuracy: 0.001)
    }

    func testDecodesCapturedRegenerationFrame() throws {
        let profile = try shippedProfile()
        let frame = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B00E60000000000"))
        let decoded = profile.decode(frame)

        let count = try XCTUnwrap(decoded.first { $0.itemNumber == 148 })
        XCTAssertEqual(count.value, 123, accuracy: 0.001)

        let mode = try XCTUnwrap(decoded.first { $0.itemNumber == 116 })
        XCTAssertEqual(mode.value, 0, accuracy: 0.001)
    }

    func testUnknownLIDDecodesToNothing() throws {
        let profile = try shippedProfile()
        let frame = try XCTUnwrap(MUT21Frame(hex: "61FF00"))
        XCTAssertTrue(profile.decode(frame).isEmpty)
    }

    func testShortFrameSkipsRatherThanFabricating() throws {
        let profile = try shippedProfile()

        // Service byte and LID only: nothing is in range, so nothing decodes.
        let empty = try XCTUnwrap(MUT21Frame(hex: "6111"))
        XCTAssertTrue(profile.decode(empty).isEmpty)

        // A two-byte reply decodes fewer parameters than the full frame.
        let partial = try XCTUnwrap(MUT21Frame(hex: "6111141F"))
        let full = try XCTUnwrap(MUT21Frame(hex: "6111141F34061D"))
        XCTAssertGreaterThan(profile.decode(full).count, profile.decode(partial).count)
    }

    func testHighlightsAreSelectedByItemNumber() throws {
        let profile = try shippedProfile()
        let frame = try XCTUnwrap(MUT21Frame(hex: "6111141F34061D"))
        let highlights = profile.highlights(from: profile.decode(frame))
        let items = Set(highlights.compactMap(\.itemNumber))
        XCTAssertTrue(items.isSubset(of: VehicleProfile.highlightItemNumbers))
        XCTAssertTrue(items.contains(155))
    }

    func testMalformedProfileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).json")
        try Data("{\"nope\":true}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try VehicleProfileLoader.load(from: url)) { error in
            guard case VehicleProfileError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testMissingProfileThrowsNotFound() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent.json")
        XCTAssertThrowsError(try VehicleProfileLoader.load(from: url)) { error in
            XCTAssertEqual(error as? VehicleProfileError, .notFound("absent.json"))
        }
    }
}

final class StandardSignalTests: XCTestCase {

    private func shippedProfile() throws -> VehicleProfile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("profiles/mitsubishi/outlander-2016-4n14.json")
        return try VehicleProfileLoader.load(from: url)
    }

    private func signal(_ pid: String, in profile: VehicleProfile) throws -> VehicleProfile.StandardSignal {
        try XCTUnwrap(profile.signals.first { $0.pid == pid }, "missing pid \(pid)")
    }

    /// Values captured from the car, decoded through the shipped profile.
    func testKnownRawValuesDecodeCorrectly() throws {
        let profile = try shippedProfile()

        // RPM 0x0A28 = 2600 / 4 = 650
        XCTAssertEqual(try signal("0C", in: profile).decode([0x0A, 0x28]) ?? 0, 650, accuracy: 0.001)
        // Coolant 0x55 = 85 - 40 = 45
        XCTAssertEqual(try signal("05", in: profile).decode([0x55]) ?? 0, 45, accuracy: 0.001)
        // Speed
        XCTAssertEqual(try signal("0D", in: profile).decode([0x00]) ?? -1, 0, accuracy: 0.001)
        // Rail pressure 0x0D2C -> 337.2 bar
        XCTAssertEqual(try signal("23", in: profile).decode([0x0D, 0x2C]) ?? 0, 337.2, accuracy: 0.01)
        // Module voltage 0x37BA -> 14.266 V
        XCTAssertEqual(try signal("42", in: profile).decode([0x37, 0xBA]) ?? 0, 14.266, accuracy: 0.001)
        // MAF 0x0257 -> 5.99 g/s
        XCTAssertEqual(try signal("10", in: profile).decode([0x02, 0x57]) ?? 0, 5.99, accuracy: 0.001)
    }

    func testLoadScaling() throws {
        let profile = try shippedProfile()
        let load = try signal("04", in: profile)
        // 0xFF is full scale.
        XCTAssertEqual(load.decode([0xFF]) ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(load.decode([0x00]) ?? -1, 0, accuracy: 0.01)
    }

    func testShortDataDoesNotFabricate() throws {
        let profile = try shippedProfile()
        XCTAssertNil(try signal("0C", in: profile).decode([0x0A]))
        XCTAssertNil(try signal("23", in: profile).decode([]))
    }

    func testTransportDescribesModulesAndProtocol() throws {
        let profile = try shippedProfile()
        XCTAssertEqual(profile.elmProtocol, "6")
        XCTAssertEqual(profile.diagnosticModules.map(\.name), ["ECM", "TCM"])
        XCTAssertEqual(profile.diagnosticModules.first?.requestHeader, "7E0")
    }

    func testProfileWithoutStandardSignalsYieldsNone() throws {
        let json = """
        {"schemaVersion":1,"id":"x","manufacturer":"X","model":"Y","year":2020,
         "engine":"1.0","notes":[],"service":{"readByLocalIdentifier":null,"readByIdentifier":null},
         "blocks":[]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try VehicleProfileLoader.load(from: url)
        XCTAssertTrue(profile.signals.isEmpty)
        XCTAssertTrue(profile.diagnosticModules.isEmpty)
        XCTAssertNil(profile.elmProtocol, "absent protocol must leave the adapter on auto-detect")
    }
}

final class GenericProfileTests: XCTestCase {

    private func profile(_ relative: String) throws -> VehicleProfile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try VehicleProfileLoader.load(from: url)
    }

    func testGenericProfileIsValid() throws {
        let generic = try profile("profiles/generic/iso15765-can.json")
        XCTAssertEqual(generic.manufacturer, "Generic")
        XCTAssertTrue(generic.blocks.isEmpty, "a generic profile has no manufacturer data")
        XCTAssertNil(generic.service.readByLocalIdentifier)
        XCTAssertGreaterThanOrEqual(generic.signals.count, 10)
    }

    func testGenericProfileDecodesLikeAnyOther() throws {
        let generic = try profile("profiles/generic/iso15765-can.json")
        let rpm = try XCTUnwrap(generic.signals.first { $0.pid == "0C" })
        XCTAssertEqual(rpm.decode([0x0A, 0x28]) ?? 0, 650, accuracy: 0.001)

        let coolant = try XCTUnwrap(generic.signals.first { $0.pid == "05" })
        XCTAssertEqual(coolant.decode([0x55]) ?? 0, 45, accuracy: 0.001)
    }

    func testGenericProfileNamesAModuleForDTCScanning() throws {
        let generic = try profile("profiles/generic/iso15765-can.json")
        XCTAssertEqual(generic.diagnosticModules.first?.requestHeader, "7E0")
    }

    /// Both shipped profiles must satisfy the same schema, or the catalogue will
    /// silently drop one at runtime.
    func testBothProfilesParse() throws {
        for path in ["profiles/mitsubishi/outlander-2016-4n14.json",
                     "profiles/generic/iso15765-can.json"] {
            let loaded = try profile(path)
            XCTAssertFalse(loaded.id.isEmpty)
            XCTAssertFalse(loaded.signals.isEmpty, "\(path) has no signals")
        }
    }
}

final class ProfileResolutionTests: XCTestCase {

    private func profile(_ relative: String) throws -> VehicleProfile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try VehicleProfileLoader.load(from: url)
    }

    private func shipped() throws -> [VehicleProfile] {
        [try profile("profiles/mitsubishi/outlander-2016-4n14.json"),
         try profile("profiles/generic/iso15765-can.json")]
    }

    /// A car that answers a manufacturer service gets the specific profile.
    func testManufacturerAvailableSelectsSpecificProfile() throws {
        let chosen = ProfileCatalog.automaticID(manufacturerAvailable: true, among: try shipped())
        XCTAssertEqual(chosen, "mitsubishi-outlander-2016-4n14")
    }

    /// A car that does not answer it gets the generic profile, not an error.
    func testManufacturerUnavailableSelectsGeneric() throws {
        let chosen = ProfileCatalog.automaticID(manufacturerAvailable: false, among: try shipped())
        XCTAssertEqual(chosen, "generic-iso15765-can")
    }

    func testNoProfilesYieldsNothing() {
        XCTAssertNil(ProfileCatalog.automaticID(manufacturerAvailable: true, among: []))
    }

    /// A generic profile declaring a manufacturer service would be a mistake, so
    /// the resolver must not treat it as specific.
    func testGenericProfileIsNotTreatedAsSpecific() throws {
        let profiles = try shipped()
        let specific = try XCTUnwrap(profiles.first { $0.manufacturer != "Generic" })
        XCTAssertEqual(ProfileCatalog.automaticID(manufacturerAvailable: true, among: [profiles[1], specific]),
                       specific.id)
    }
}
