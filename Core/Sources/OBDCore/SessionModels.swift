import Foundation

/// On-disk session formats. Everything is line-delimited JSON: one complete
/// object per line, append-only. NDJSON is canonical; CSV is never written.
///
/// See `docs/architecture.md` for the contract these types implement.
public enum SessionSchema {
    /// Bumped when a field's meaning changes, not merely when one is added.
    ///
    /// 2: `pid` became optional so service `0x21` observations can carry a
    /// local identifier instead.
    /// 3: `unit` is omitted when unknown rather than written as an empty string.
    public static let version = 3
}

public struct SessionManifest: Codable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String
    public var startedAt: String
    public var finishedAt: String?
    public var appVersion: String
    public var vehicleProfileID: String?
    public var adapterName: String?
    public var adapterIdentifier: String?
    public var supportedPIDs: [String]?
    public var notes: [String]

    public init(
        schemaVersion: Int = SessionSchema.version,
        sessionID: String,
        startedAt: String,
        finishedAt: String? = nil,
        appVersion: String,
        vehicleProfileID: String? = nil,
        adapterName: String? = nil,
        adapterIdentifier: String? = nil,
        supportedPIDs: [String]? = nil,
        notes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.appVersion = appVersion
        self.vehicleProfileID = vehicleProfileID
        self.adapterName = adapterName
        self.adapterIdentifier = adapterIdentifier
        self.supportedPIDs = supportedPIDs
        self.notes = notes
    }
}

/// One successful observation. There is deliberately no "all signals at once"
/// record: reads happen separately and may fail, so each observation carries its
/// own timestamp.
public struct SampleRecord: Codable, Equatable {
    public var schemaVersion: Int
    public var elapsedMs: Int
    public var wallTime: String
    /// Standard OBD PID, when the observation came from mode `01`.
    public var pid: String?
    /// Diagnostic service, for manufacturer observations (`"21"`).
    public var service: String?
    /// Local identifier within that service.
    public var lid: String?
    /// Manufacturer data-list item number, when the profile provides one.
    public var itemNumber: Int?
    public var name: String
    public var value: Double
    /// Omitted when the profile does not know the engineering unit.
    public var unit: String?
    /// Raw response payload, so a decoding bug can be corrected later without
    /// re-driving the car.
    public var raw: String?

    public init(
        schemaVersion: Int = SessionSchema.version,
        elapsedMs: Int,
        wallTime: String,
        pid: UInt8,
        name: String,
        value: Double,
        unit: String,
        raw: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.elapsedMs = elapsedMs
        self.wallTime = wallTime
        self.pid = String(format: "%02X", pid)
        self.name = name
        self.value = value
        self.unit = unit.isEmpty ? nil : unit
        self.raw = raw
    }

    /// A manufacturer observation from service `0x21`.
    public init(
        schemaVersion: Int = SessionSchema.version,
        elapsedMs: Int,
        wallTime: String,
        service: UInt8,
        lid: UInt8,
        itemNumber: Int?,
        name: String,
        value: Double,
        unit: String?,
        raw: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.elapsedMs = elapsedMs
        self.wallTime = wallTime
        self.pid = nil
        self.service = String(format: "%02X", service)
        self.lid = String(format: "%02X", lid)
        self.itemNumber = itemNumber
        self.name = name
        self.value = value
        self.unit = (unit?.isEmpty ?? true) ? nil : unit
        self.raw = raw
    }
}

public enum SessionEventType: String, Codable {
    case sessionStarted = "session_started"
    case sessionStopped = "session_stopped"
    case adapterConnected = "adapter_connected"
    case adapterDisconnected = "adapter_disconnected"
    case recordingInterrupted = "recording_interrupted"
    case batteryTest = "battery_test"
    case dtcSnapshot = "dtc_snapshot"
    case error = "error"
}

public struct EventRecord: Codable, Equatable {
    public var schemaVersion: Int
    public var elapsedMs: Int
    public var wallTime: String
    public var type: SessionEventType
    public var details: [String: String]

    public init(
        schemaVersion: Int = SessionSchema.version,
        elapsedMs: Int,
        wallTime: String,
        type: SessionEventType,
        details: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.elapsedMs = elapsedMs
        self.wallTime = wallTime
        self.type = type
        self.details = details
    }
}
