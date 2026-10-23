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

    /// Newest first. Tolerant of a session that never finished: those are shown
    /// as incomplete rather than hidden.
    static func summaries(root: URL? = nil) -> [SessionSummary] {
        sessions(root: root).map { directory in
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
    }
}
