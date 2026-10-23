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
