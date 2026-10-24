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

    /// The identity block is what lets the app recognise the car with no VIN or
    /// calibration read. Every reference in it has to exist, or the profile
    /// silently stops being identifiable.
    func testIdentityBlockReferencesRealParameters() throws {
        let profile = try shippedProfile()
        let identity = try XCTUnwrap(profile.identity, "the shipped profile should be identifiable from live data")

        for lid in identity.probeLIDs {
            XCTAssertNotNil(UInt8(lid, radix: 16), "probe lid \(lid) is not a hex byte")
            XCTAssertTrue(profile.blocks.contains { $0.lid.lowercased() == lid.lowercased() },
                          "probe lid \(lid) has no block")
        }

        var parameters: [Int: VehicleProfile.Parameter] = [:]
        for block in profile.blocks {
            for parameter in block.parameters {
                if let number = parameter.itemNumber { parameters[number] = parameter }
            }
        }
        let polledPIDs = Set(profile.signals.compactMap { UInt8($0.pid, radix: 16) })

        XCTAssertTrue(identity.discriminators.contains { $0.required == true },
                      "agreement needs a required discriminator")
        for rule in identity.discriminators {
            XCTAssertNotNil(parameters[rule.itemNumber], "item \(rule.itemNumber) is in no block")
            let pid = try XCTUnwrap(rule.pidValue)
            XCTAssertTrue(polledPIDs.contains(pid),
                          "PID \(rule.sameAsPID) is not polled, so it cannot be a reference")
        }
        for rule in identity.plausibility ?? [] {
            XCTAssertNotNil(parameters[rule.itemNumber], "item \(rule.itemNumber) is in no block")
            XCTAssertLessThan(rule.min, rule.max)
        }
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

        let role = try XCTUnwrap(profile.roles?.sootByAccumulation)
        XCTAssertEqual(try XCTUnwrap(role.value(in: decoded)), 2.6, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(profile.roles?.sootByPressure?.value(in: decoded)),
            0.3,
            accuracy: 0.001)
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

    /// A field pinned at the ECU's clamp is the absence of a measurement. Raw
    /// 230 decodes to 950 °C on this car's NTC input, which is not fitted, and
    /// on the stored maximum fields. Showing 950 would invent a reading.
    func testSentinelValuesAreOmittedRatherThanShown() throws {
        let profile = try shippedProfile()

        // LID 0x10, byte 7 (NTC) at 0xE6 = 230.
        let pinned = try XCTUnwrap(MUT21Frame(hex: "61103233301400E6"))
        let decoded = profile.decode(pinned)
        XCTAssertNil(decoded.first { $0.itemNumber == 511 })
        XCTAssertNotNil(decoded.first { $0.itemNumber == 117 }, "the other temperatures still decode")

        // The same frame with a real reading keeps the parameter.
        let real = try XCTUnwrap(MUT21Frame(hex: "6110323330140030"))
        XCTAssertNotNil(profile.decode(real).first { $0.itemNumber == 511 })

        // LID 0x12, byte 3 = stored DPF maximum.
        let storedMax = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B00E60000000000"))
        XCTAssertNil(profile.decode(storedMax).first { $0.itemNumber == 127 })
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
        let configured = Set(try XCTUnwrap(profile.roles?.highlights))
        XCTAssertTrue(items.isSubset(of: configured))
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

    private func loadInline(_ json: String) throws -> VehicleProfile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("validate-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try VehicleProfileLoader.load(from: url)
    }

    func testValidatorRejectsNegativeParameterLength() {
        let json = """
        {"schemaVersion":1,"id":"x","manufacturer":"X","model":"Y","year":2020,
         "engine":"1.0","service":{"readByLocalIdentifier":"21","readByIdentifier":null},
         "blocks":[{"lid":"11","parameters":[
           {"itemNumber":1,"name":"bad","byte":2,"length":-1,"factor":1,"offset":0}
         ]}]}
        """
        XCTAssertThrowsError(try loadInline(json)) { error in
            guard case VehicleProfileError.malformed(let message) = error else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(message.contains("unsupported length"), message)
        }
    }

    func testValidatorRejectsObservedValueThatDisagreesWithScaling() {
        let json = """
        {"schemaVersion":1,"id":"x","manufacturer":"X","model":"Y","year":2020,
         "engine":"1.0","service":{"readByLocalIdentifier":"21","readByIdentifier":null},
         "blocks":[{"lid":"11","parameters":[
           {"itemNumber":1,"name":"switch","byte":2,"length":1,"factor":1,"offset":0,
            "observed":{"raw":2,"value":0}}
         ]}]}
        """
        XCTAssertThrowsError(try loadInline(json)) { error in
            guard case VehicleProfileError.malformed(let message) = error else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(message.contains("observed value"), message)
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
         "engine":"1.0","service":{"readByLocalIdentifier":null,"readByIdentifier":null}}
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

final class VehicleIdentityDecoderTests: XCTestCase {

    /// Captured from the car.
    func testDecodesVIN() {
        let vin = VehicleIdentityDecoder.vin(fromHex: "4902014A4D46584C47463657485A303030363531")
        XCTAssertEqual(vin, "JMFXLGF6WHZ000651")
    }

    func testDecodesCalibrationID() {
        let calid = VehicleIdentityDecoder.calibrationID(fromHex: "49040131383630433937323031")
        XCTAssertEqual(calid, "1860C97201")
    }

    func testRejectsWrongService() {
        XCTAssertNil(VehicleIdentityDecoder.vin(fromHex: "410C0A28"))
        XCTAssertNil(VehicleIdentityDecoder.calibrationID(fromHex: "4902014A4D46"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(VehicleIdentityDecoder.vin(fromHex: "4902"))
    }
}
