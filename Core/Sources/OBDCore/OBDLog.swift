import OSLog

/// The app's own console trail.
///
/// The NDJSON session is the record of what the car did; this is the record of
/// what the *app* did. They are not interchangeable: a suspended process writes
/// no NDJSON, so only the system log can show that it was suspended rather than
/// the car going quiet. Keep these messages about state, not sample values.
public enum OBDLog {
    public static let recording = Logger(subsystem: "com.naleen.obdlogger", category: "recording")
    public static let link = Logger(subsystem: "com.naleen.obdlogger", category: "link")
    public static let lifecycle = Logger(subsystem: "com.naleen.obdlogger", category: "lifecycle")
}
