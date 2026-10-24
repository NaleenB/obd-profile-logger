import XCTest
@testable import OBDCore

final class SessionIDTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// The directory name follows the recording device's clock, not UTC. This is
    /// the session from 24 Oct 07:43 local, which UTC named the 23rd.
    func testIDUsesLocalTime() {
        let brisbane = TimeZone(identifier: "Australia/Brisbane")!
        let id = SessionStore.makeSessionID(
            now: date("2026-10-23T21:43:18Z"), timeZone: brisbane)
        XCTAssertTrue(id.hasPrefix("20261024-074318"), id)
        XCTAssertEqual(id.count, 20, "yyyyMMdd-HHmmss plus a hyphen and four hex")
    }

    /// The same instant gets a different name in a different zone, which is the
    /// point: the name is what the driver reads.
    func testIDFollowsTheProvidedZone() {
        let id = SessionStore.makeSessionID(
            now: date("2026-10-23T21:43:18Z"),
            timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
        XCTAssertTrue(id.hasPrefix("20261023-164318"), id)
    }

    /// Two names in the same second cannot collide.
    func testIDIsUniqueWithinASecond() {
        let now = date("2026-10-23T21:43:18Z")
        let ids = Set((0..<50).map { _ in
            SessionStore.makeSessionID(now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        })
        XCTAssertEqual(ids.count, 50)
    }

    /// A store can hold UTC-named and local-named sessions at once. Ordering
    /// comes from `startedAt`, so the list stays chronological regardless.
    func testSummariesSortByStartedAtNotName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-ids-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The first name sorts after the second, but was recorded years earlier.
        let older = SessionManifest(
            sessionID: "20990101-000000-aaaa",
            startedAt: "2020-01-01T00:00:00.000Z",
            appVersion: "test")
        let newer = SessionManifest(
            sessionID: "20000101-000000-bbbb",
            startedAt: "2026-10-24T07:43:18.964Z",
            appVersion: "test")

        for manifest in [older, newer] {
            let recorder = try SessionStore.createSession(root: root, manifest: manifest)
            recorder.finish(reason: "test")
        }

        let ids = SessionStore.summaries(root: root).map(\.id)
        XCTAssertEqual(ids, ["20000101-000000-bbbb", "20990101-000000-aaaa"])
    }
}
