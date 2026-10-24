import Foundation

/// A recorded session as shown in a list. Cheap to build: it reads the manifest
/// and counts lines rather than loading the data.
public struct SessionSummary: Identifiable, Equatable {
    public let directory: URL
    public let startedAt: String?
    public let finished: Bool
    public let sampleCount: Int
    public let eventCount: Int
    public let adapterName: String?
    public let vehicleProfileID: String?

    public var id: String { directory.lastPathComponent }

    public init(
        directory: URL,
        startedAt: String?,
        finished: Bool,
        sampleCount: Int,
        eventCount: Int,
        adapterName: String?,
        vehicleProfileID: String?
    ) {
        self.directory = directory
        self.startedAt = startedAt
        self.finished = finished
        self.sampleCount = sampleCount
        self.eventCount = eventCount
        self.adapterName = adapterName
        self.vehicleProfileID = vehicleProfileID
    }

    /// "2026-10-23 15:23" in local time, or the raw id when unparseable.
    public var displayTimestamp: String {
        guard let startedAt,
              let date = ISO8601DateFormatter().date(from: startedAt) else {
            return id
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public var durationDescription: String {
        finished ? "\(sampleCount) samples" : "incomplete (\(sampleCount) samples)"
    }
}

public extension SessionStore {

    /// Newest first, by recorded start time rather than by directory name.
    ///
    /// Names use the recording device's local time, so a store that has moved
    /// between timezones — or predates the change from UTC names — does not sort
    /// correctly by string. `startedAt` is UTC and authoritative.
    /// Incomplete sessions are shown as such rather than hidden.
    static func summaries(root: URL? = nil) -> [SessionSummary] {
        let all = sessions(root: root).map { directory in
            let manifest = readManifest(at: directory)
            return SessionSummary(
                directory: directory,
                startedAt: manifest?.startedAt,
                finished: manifest?.finishedAt != nil,
                sampleCount: lineCount(at: directory, filename: SessionRecorder.samplesFilename()),
                eventCount: lineCount(at: directory, filename: SessionRecorder.eventsFilename()),
                adapterName: manifest?.adapterName,
                vehicleProfileID: manifest?.vehicleProfileID
            )
        }
        return all.sorted { lhs, rhs in
            // A manifest that cannot be read falls back to its name.
            (lhs.startedAt ?? lhs.id) > (rhs.startedAt ?? rhs.id)
        }
    }
}
