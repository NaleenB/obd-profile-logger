import Foundation
import Observation
import OBDLink
import OBDCore

@MainActor
@Observable
final class LiveModel {

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    enum RecordingState: Equatable {
        case idle
        case recording(sessionID: String)
        case stopped(sessionID: String)
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    var phase: Phase = .idle
    var status = "Not connected"
    var adapterName = ""
    /// Everything live, cleared as one unit on disconnect.
    private(set) var readings = LiveReadings()
    var dpf: DPFStatus?

    var values: [String: Double] { readings.values }
    var manufacturer: [String: DecodedParameter] { readings.manufacturer }
    var lastUpdate: Date? { readings.lastUpdate }
    private(set) var profile: VehicleProfile?

    /// Latest DTC scan, shown in the UI. Updated on every scan; the event stream
    /// dedupes separately.
    private(set) var diagnostics: VehicleDiagnostics?
    private(set) var diagnosticsAt: Date?

    var recording: RecordingState = .idle
    var lastSessionURL: URL?
    var exportURL: URL?
    /// Which session the prepared ZIP belongs to, so it can be discarded if that
    /// session is deleted.
    private(set) var exportedSessionID: String?
    var notice: String?

    private let transport = BLETransport()
    private let session = RecordingSession()
    private var elm: ELMClient?
    private var pollTask: Task<Void, Never>?

    private let battery = BatteryMonitor()
    private let batteryClock = UptimeClock()
    private var lastRPM: Double?
    private(set) var batteryReport: BatteryReport?
    private var batteryLogged = false
    private var runningSince: Date?
    private var gapMonitor = DataGapMonitor(threshold: 10)
    /// Survives `readings.clear()` so a link outage can still be represented as
    /// a data gap after reconnection. `readings.lastUpdate` alone cannot do this
    /// because disconnect deliberately clears stale displayed values.
    private var lastSampleAt: Date?
    private var firstSampleAt: Date?
    private var identity = VehicleIdentity()
    private var identityResolved = false
    private var odometerKm: Int?
    /// The session's starting odometer. Kept apart from `odometerKm` because the
    /// first successful read often arrives after recording has started: the
    /// engine must be identified before the ECU answers service 0x21 at all.
    private var odometerStartKm: Int?
    private var lastOdometerRead = Date.distantPast
    private var ambientTempC: Double?
    private var profileURL: URL?
    private var lastSessionEnd: Date? =
        UserDefaults.standard.object(forKey: "lastSessionEnd") as? Date
    private var intentionalDisconnect = false
    private let watchdog = IdleWatchdog(timeout: 600)
    /// When a command is outstanding. A request whose continuation never resumes
    /// leaves this set, which is how a suspended-then-resumed link is detected.
    private var lastLoopTick: Date?
    private var didInitialReads = false
    private var connectStartedAt: Date?
    private var engineStoppedSince: Date?
    private var regenDetector = RegenDetector()
    private var regenSootAtStart: Double?
    private var stallWatchdog: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGate = SingleAttemptGate<ConnectionEpoch.Token>()
    /// Waits for a cancelled reconnect to relinquish the shared transport before
    /// starting its replacement.
    private var reconnectRestartTask: Task<Void, Never>?
    /// The attempt currently permitted to act on the shared BLE transport.
    private var transportLease = ConnectionLease<ConnectionEpoch.Token>()
    private var connectedAt: Date?
    /// Changes whenever a connection attempt or poll session is superseded.
    /// Cancellation is cooperative; this identity is what stops an old request
    /// from committing state after its continuation finally returns.
    private var connectionEpoch = ConnectionEpoch()
    /// Decides when silence becomes a message and when it becomes a cheaper loop.
    private let silence = SilenceWatchdog()
    /// Voltage at the adapter, readable with the ignition off. Only meaningful
    /// as a fallback: while the ECU answers, PID `42` is the real measurement.
    private(set) var supplyVolts: Double?

    private var scanner: DTCScanner?
    private var snapshotGate = DTCSnapshotGate()
    private var sweep = SweepPass(planned: [])
    private var lastDTCStep = Date.distantPast

    /// Roughly 10 s between DTC scans at the current poll cadence.
    private let dtcScanInterval: TimeInterval = 10

    // MARK: Profile identification

    /// Identifier in use. Starts generic and changes only when the car provides
    /// evidence; there is no user-facing choice.
    private(set) var profileID: String = ProfileCatalog.genericID
    /// How it was chosen: calibration, vin, agreement, none or override.
    private(set) var profileMatchMethod: String = ProfileResolver.Method.none.rawValue
    /// True once the retry budget is spent without an answer.
    private(set) var identificationExhausted = false

    private var identificationAttempts = 0
    private var nextIdentificationAt: Date?
    private var verificationDone = false
    private var lastVerificationAttempt = Date.distantPast
    private var profileReason = ""

    /// Profiles bundled with the app, used as resolver candidates.
    let availableProfiles = ProfileCatalog.entries()
    @ObservationIgnored
    private lazy var candidateProfiles: [VehicleProfile] = availableProfiles.compactMap {
        try? ProfileCatalog.load(id: resourceName(for: $0.id))
    }

    /// A development escape hatch, never reachable from the interface.
    private let overrideProfileID: String? = {
        guard let id = UserDefaults.standard.string(forKey: "ProfileOverride"),
              ProfileCatalog.entries().contains(where: { $0.id == id })
        else { return nil }
        return id
    }()

    /// True when the car answered a manufacturer service at connect time.
    private(set) var manufacturerServiceAvailable = false

    init() {
        // A profile chosen by hand in an older build would defeat automatic
        // identification, so it is discarded rather than migrated.
        UserDefaults.standard.removeObject(forKey: "profileSelection")
        if let overrideProfileID {
            loadProfile(id: overrideProfileID)
            profileMatchMethod = ProfileResolver.Method.override.rawValue
        } else {
            loadProfile(id: ProfileCatalog.genericID)
        }
    }

    private func loadProfile(id: String) {
        profileID = id
        profileURL = Bundle.main.url(forResource: resourceName(for: id), withExtension: "json")
        do {
            profile = try ProfileCatalog.load(id: resourceName(for: id))
        } catch {
            profile = nil
            notice = "Vehicle profile unavailable: \(error)"
        }
        sweep = SweepPass(planned: profile?.localIdentifiers ?? [])
    }

    /// A manual connection starts a new vehicle session. Reusing the profile a
    /// previous car proved would decode the new car's manufacturer blocks with
    /// the wrong offsets and stamp the manifest with a match that never
    /// happened.
    ///
    /// An in-session reconnect deliberately does not call this: it is still the
    /// same car and must keep the profile and its odometer context.
    func resetForNewSession() {
        // Clear the previous session's notice before the profile load can set a
        // real one (an unavailable bundled profile).
        notice = nil
        if let overrideProfileID {
            loadProfile(id: overrideProfileID)
            profileMatchMethod = ProfileResolver.Method.override.rawValue
        } else {
            loadProfile(id: ProfileCatalog.genericID)
            profileMatchMethod = ProfileResolver.Method.none.rawValue
        }
        profileReason = ""
        manufacturerServiceAvailable = false
        identity = VehicleIdentity()
        identityResolved = false
        identificationAttempts = 0
        identificationExhausted = false
        verificationDone = false
        lastVerificationAttempt = .distantPast
        nextIdentificationAt = Date()

        diagnostics = nil
        diagnosticsAt = nil
        batteryReport = nil
        batteryLogged = false
        runningSince = nil
        odometerKm = nil
        odometerStartKm = nil
        ambientTempC = nil
        lastOdometerRead = .distantPast
        lastDTCStep = .distantPast
        manufacturerProbeTimings = [:]

        supportedPIDs = []
        discoveryResult = PIDDiscovery()
        discovery = .notRun
        discoveryRetryDone = false
        discoveryAtRecordingStart = .notRun

        lastSampleAt = nil
        firstSampleAt = nil
        lastRPM = nil
        supplyVolts = nil
        connectedAt = nil
        lastLoopTick = nil
        engineStoppedSince = nil
        didInitialReads = false
        gapMonitor = DataGapMonitor(threshold: 10)
        battery.reset()
        protocolDescription = ""
        detectedProtocolNumber = nil
        readings.clear()
        dpf = nil
        rebuildSignalList()
    }

    /// A profile is applied only when the required discriminators agree on three
    /// consecutive probes. The probes are a few hundred milliseconds apart, so
    /// identification still completes in seconds.
    private static let agreementProbes = 3
    private static let probeInterval: UInt64 = 400_000_000
    /// Retry budget after connect. A cold ECU answers once it wakes; a car with
    /// no matching profile should not cost requests for the whole session.
    private static let identificationDelays: [TimeInterval] = [0, 15, 30, 60, 120, 300]

    /// Asks the car what it is. This is the only route to a manufacturer
    /// profile: there is no setting and no assumption.
    private func attemptIdentification(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        guard overrideProfileID == nil,
              profileMatchMethod == ProfileResolver.Method.none.rawValue else { return }

        // The service probe is only meaningful while the ECU is awake. A car
        // that was asleep at connect can start answering later, and without
        // this re-check the agreement route would stay unavailable.
        if !manufacturerServiceAvailable {
            let available = await detectManufacturerService(using: elm)
            guard isCurrent(generation) else { return }
            manufacturerServiceAvailable = available
        }
        if !identityResolved {
            let read = await readIdentity(using: elm)
            guard isCurrent(generation) else { return }
            identity = read
            identityResolved = identity.calibrationID != nil || identity.vin != nil
        }

        // Identity is exact, so manufacturer data is only decoded when it has
        // nothing to say.
        var resolution = ProfileResolver.resolve(
            candidates: candidateProfiles,
            identity: identity,
            manufacturerAvailable: false)

        if !resolution.isResolved, manufacturerServiceAvailable {
            resolution = await resolveByAgreement(using: elm) ?? resolution
        }

        guard isCurrent(generation) else { return }
        profileReason = resolution.reason
        apply(resolution)

        if resolution.isResolved {
            nextIdentificationAt = nil
            identificationExhausted = false
        } else {
            identificationAttempts += 1
            scheduleNextIdentification()
        }
    }

    /// Decodes the same evidence each bundled profile asks for.
    private func gatherEvidence(using elm: ELMClient)
        async -> (standard: [UInt8: Double], decoded: [String: [Int: Double]]) {
        var standard: [UInt8: Double] = [:]
        var decoded: [String: [Int: Double]] = [:]

        let referencedPIDs = Set(candidateProfiles.compactMap(\.identity)
            .flatMap { $0.discriminators.compactMap(\.pidValue) })
        for pid in referencedPIDs {
            guard !Task.isCancelled else { return (standard, decoded) }
            if let value = await readStandard(pid, using: elm) {
                standard[pid] = value
            }
        }

        let probeLIDs = Set(candidateProfiles.compactMap(\.identity).flatMap(\.lidValues))
        guard !probeLIDs.isEmpty else { return (standard, decoded) }

        var frames: [UInt8: MUT21Frame] = [:]
        await selectManufacturerHeader(using: elm)
        for lid in probeLIDs.sorted() {
            guard !Task.isCancelled else { return (standard, decoded) }
            if let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
               let hex = reply.payloadHex,
               let frame = MUT21Frame(hex: hex) {
                frames[lid] = frame
            }
        }
        await restoreBroadcastHeader(using: elm)
        if !frames.isEmpty { manufacturerServiceAvailable = true }

        for profile in candidateProfiles {
            guard let spec = profile.identity else { continue }
            var values: [Int: Double] = [:]
            for lid in spec.lidValues {
                guard let frame = frames[lid] else { continue }
                for value in profile.decode(frame) {
                    if let item = value.itemNumber { values[item] = value.value }
                }
            }
            decoded[profile.id] = values
        }
        return (standard, decoded)
    }

    private func assess(_ evidence: (standard: [UInt8: Double], decoded: [String: [Int: Double]]))
        -> [ProfileAssessment] {
        candidateProfiles.compactMap { profile in
            guard profile.identity != nil else { return nil }
            return ProfileMatcher.assess(profile: profile,
                                         manufacturer: evidence.decoded[profile.id] ?? [:],
                                         standard: evidence.standard)
        }
    }

    /// Repeats the comparison so one lucky byte cannot promote a profile.
    private func resolveByAgreement(using elm: ELMClient) async -> ProfileResolver.Resolution? {
        var streak: [String: Int] = [:]
        var resolution: ProfileResolver.Resolution?

        for round in 0..<Self.agreementProbes {
            guard !Task.isCancelled else { return resolution }
            let evidence = await gatherEvidence(using: elm)
            let current = assess(evidence)
            for assessment in current {
                streak[assessment.profileID] = assessment.convincing
                    ? (streak[assessment.profileID] ?? 0) + 1
                    : 0
            }
            let sustained = current.map { assessment in
                ProfileAssessment(
                    profileID: assessment.profileID,
                    score: assessment.score,
                    convincing: assessment.convincing
                        && (streak[assessment.profileID] ?? 0) >= Self.agreementProbes,
                    contradicted: assessment.contradicted,
                    evidence: assessment.evidence
                )
            }
            resolution = ProfileResolver.resolve(
                candidates: candidateProfiles,
                identity: identity,
                manufacturerAvailable: true,
                assessments: sustained)

            // With the engine off every layout "agrees" on zero, and repeating
            // the probe cannot change that.
            if round == 0, !hasUsableReference(evidence.standard) { break }
            if resolution?.isResolved == true { break }
            if round < Self.agreementProbes - 1 {
                try? await Task.sleep(nanoseconds: Self.probeInterval)
            }
        }
        return resolution
    }

    /// True when at least one required discriminator has a reference value above
    /// its declared floor, so the comparison means something.
    private func hasUsableReference(_ standard: [UInt8: Double]) -> Bool {
        candidateProfiles.contains { profile in
            profile.identity?.discriminators.contains { rule in
                guard rule.required == true, let pid = rule.pidValue else { return false }
                let reference = standard[pid] ?? 0
                return reference > 0 && reference >= (rule.minimumStandard ?? 0)
            } ?? false
        }
    }

    private func scheduleNextIdentification() {
        guard identificationAttempts < Self.identificationDelays.count else {
            identificationExhausted = true
            nextIdentificationAt = nil
            return
        }
        nextIdentificationAt = Date()
            .addingTimeInterval(Self.identificationDelays[identificationAttempts])
    }

    private func identificationIsDue(now: Date = Date()) -> Bool {
        guard overrideProfileID == nil,
              profileMatchMethod == ProfileResolver.Method.none.rawValue,
              !identificationExhausted,
              let nextIdentificationAt else { return false }
        return now >= nextIdentificationAt
    }

    /// Applies a resolution. A change of profile mid-session is recorded rather
    /// than hidden: the samples carry their own names and units, so a boundary
    /// event is enough to attribute them.
    func apply(_ resolution: ProfileResolver.Resolution) {
        guard let id = resolution.profileID else {
            profileMatchMethod = ProfileResolver.Method.none.rawValue
            return
        }
        guard id != profileID else {
            profileMatchMethod = resolution.method.rawValue
            return
        }

        let previous = profileID
        loadProfile(id: id)
        profileMatchMethod = resolution.method.rawValue
        // Service 0x21 only answers once the car is identified, so this is the
        // moment the odometer first becomes readable. Ask on the next cycle
        // rather than waiting out the periodic interval.
        lastOdometerRead = .distantPast
        readings.clearManufacturer()
        dpf = nil
        rebuildSignalList()

        if isRecording {
            session.event(.profileChanged, [
                "from": previous,
                "to": id,
                "method": resolution.method.rawValue,
                "reason": resolution.reason
            ])
            let data = profileURL.flatMap { try? Data(contentsOf: $0) }
            if let data {
                try? session.replaceProfileCopy(with: data)
            }
            // Write the manifest now, not only at stop: if this session is
            // killed mid-recording, the manifest must still describe the
            // samples it holds.
            session.updateProfile(
                id: id,
                hash: data.map(ProfileFingerprint.hash(of:)),
                match: resolution.method.rawValue
            )
        }
        notice = "\(profileDisplayName(id)) profile applied (\(resolution.method.rawValue))."
    }

    private func profileDisplayName(_ id: String) -> String {
        if id == ProfileCatalog.genericID { return "Standard OBD" }
        return availableProfiles.first { $0.id == id }?.title ?? id
    }

    /// Standard PID for a discriminator, decoded with a profile's own scaling so
    /// no formula is hardcoded here.
    private func readStandard(_ pid: UInt8, using elm: ELMClient) async -> Double? {
        await selectEngineHeader(using: elm)
        let reply = try? await elm.send(String(format: "01%02X", pid), timeout: 2)
        await restoreBroadcastHeader(using: elm)
        guard let hex = reply?.payloadHex,
              hex.hasPrefix(String(format: "41%02X", pid)),
              let data = LiveModel.bytes(String(hex.dropFirst(4)))
        else { return nil }
        let signal = candidateProfiles.lazy
            .compactMap { $0.signals.first { $0.pidValue == pid } }
            .first
        return signal?.decode(data)
    }

    /// A profile matched by calibration or VIN should still behave like itself.
    /// A failed probe is retried: only a completed comparison sets `verified`,
    /// so one timeout cannot disable the safeguard for the whole session.
    private func verifyResolvedProfile(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        guard !verificationDone,
              manufacturerServiceAvailable,
              let profile, let spec = profile.identity,
              let lastRPM, lastRPM > 400,
              Date().timeIntervalSince(lastVerificationAttempt) >= 30
        else { return }
        lastVerificationAttempt = Date()

        var values: [Int: Double] = [:]
        await selectManufacturerHeader(using: elm)
        for lid in spec.lidValues {
            guard !Task.isCancelled else { return }
            if let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
               let hex = reply.payloadHex,
               let frame = MUT21Frame(hex: hex) {
                manufacturerServiceAvailable = true
                for value in profile.decode(frame) {
                    if let item = value.itemNumber { values[item] = value.value }
                }
            }
        }
        await restoreBroadcastHeader(using: elm)

        guard isCurrent(generation) else { return }

        // Read the reference immediately after the manufacturer frames. Using
        // `lastRPM` from several seconds earlier made normal idle fluctuation
        // look like a layout disagreement.
        guard let rpm = await readStandard(0x0C, using: elm), rpm > 400 else {
            // A failed fresh read proves nothing. Try again after the throttle.
            return
        }
        var standard: [UInt8: Double] = [0x0C: rpm]
        if let coolant = await readStandard(0x05, using: elm) {
            standard[0x05] = coolant
        }
        guard isCurrent(generation) else { return }
        // Without both sides of the comparison there is nothing to judge. Try
        // again later rather than calling an unanswered probe a pass.
        guard ProfileMatcher.hasRequiredEvidence(
            profile: profile, manufacturer: values, standard: standard)
        else { return }
        verificationDone = true

        let assessment = ProfileMatcher.assess(
            profile: profile, manufacturer: values, standard: standard)
        guard assessment.contradicted else { return }

        if isRecording {
            session.event(.profileDisagreement, [
                "profile": profile.id,
                "match": profileMatchMethod,
                "evidence": assessment.evidence.joined(separator: "; ")
            ])
        }
        notice = "Profile matched by \(profileMatchMethod), but its live data disagrees."
    }

    /// VIN and calibration ID, used to decide whether a profile's byte offsets
    /// apply to this specific ECU.
    private func readIdentity(using elm: ELMClient) async -> VehicleIdentity {
        var identity = VehicleIdentity()
        await selectEngineHeader(using: elm)
        if let reply = try? await elm.send("0902", timeout: 5), let hex = reply.payloadHex {
            identity.vin = VehicleIdentityDecoder.vin(fromHex: hex)
        }
        if let reply = try? await elm.send("0904", timeout: 5), let hex = reply.payloadHex {
            identity.calibrationID = VehicleIdentityDecoder.calibrationID(fromHex: hex)
        }
        await restoreBroadcastHeader(using: elm)
        return identity
    }

    /// Sends a known manufacturer request and sees whether anything answers.
    /// One command, so it costs about a tenth of a second.
    /// Timings for the pre-polling probe of service `0x21`, in milliseconds.
    ///
    /// Two `ATSH` commands costing seconds instead of milliseconds means the
    /// adapter was still busy with an earlier reply, not that the car is slow —
    /// a distinction the whole-connection total cannot make.
    private var manufacturerProbeTimings: [String: String] = [:]

    private func detectManufacturerService(using elm: ELMClient) async -> Bool {
        var timings: [String: String] = [:]
        let probeStart = Date()

        let headerStart = Date()
        await selectManufacturerHeader(using: elm)
        timings["selectHeaderMs"] = Self.millis(Date().timeIntervalSince(headerStart) * 1000)

        let replyStart = Date()
        let reply = try? await elm.send("2111", timeout: 3)
        timings["mutReplyMs"] = Self.millis(Date().timeIntervalSince(replyStart) * 1000)

        let restoreStart = Date()
        await restoreBroadcastHeader(using: elm)
        timings["restoreHeaderMs"] = Self.millis(Date().timeIntervalSince(restoreStart) * 1000)

        timings["probeTotalMs"] = Self.millis(Date().timeIntervalSince(probeStart) * 1000)
        manufacturerProbeTimings = timings

        guard let hex = reply?.payloadHex else { return false }
        return hex.hasPrefix("6111")
    }

    /// Profile ids are dotted and human-readable; bundle resources are shorter
    /// file names. The catalogue owns that mapping.
    private func resourceName(for id: String) -> String {
        ProfileCatalog.resourceName(for: id) ?? id
    }

    /// What the app decided and why. Information, not a control: there is no
    /// way to pick a profile by hand.
    var profileCaption: String {
        switch profileMatchMethod {
        case ProfileResolver.Method.calibration.rawValue:
            return "\(profileDisplayName(profileID)) · calibration"
        case ProfileResolver.Method.vin.rawValue:
            return "\(profileDisplayName(profileID)) · VIN"
        case ProfileResolver.Method.agreement.rawValue:
            return "\(profileDisplayName(profileID)) · live data"
        case ProfileResolver.Method.override.rawValue:
            return "\(profileDisplayName(profileID)) · override"
        default:
            if !manufacturerServiceAvailable || identificationExhausted {
                return "Standard OBD · no matching profile"
            }
            return "Standard OBD · identifying"
        }
    }

    var isConnected: Bool { phase == .connected }

    /// Session currently being written, if any. Used to protect it from deletion.
    var activeSessionID: String? {
        if case .recording(let id) = recording { return id }
        return nil
    }

    /// Called after sessions are deleted so stale references and temporary ZIPs
    /// are not kept around.
    func handleSessionsDeleted(_ ids: Set<String>) {
        if let directory = lastSessionURL, ids.contains(directory.lastPathComponent) {
            lastSessionURL = nil
        }
        if let exportedSessionID, ids.contains(exportedSessionID) {
            if let exportURL { SessionArchive.discard(exportURL) }
            exportURL = nil
            self.exportedSessionID = nil
        }
    }
    var isRecording: Bool { recording.isRecording }

    func isStandardStale(_ pid: String, now: Date = Date()) -> Bool {
        readings.isStandardStale(pid, now: now, after: 5)
    }

    func isManufacturerStale(_ parameter: DecodedParameter, now: Date = Date()) -> Bool {
        readings.isManufacturerStale(parameter, now: now, after: 10)
    }

    var manufacturerHighlights: [DecodedParameter] {
        guard let profile else { return [] }
        return profile.highlights(from: Array(manufacturer.values))
    }

    /// Signals actually displayed. Profile first, generic fallback second, and
    /// filtered to what the car reports supporting when that is known.
    ///
    /// This is why an unsupported PID never becomes a permanent dash: it is
    /// dropped from the list instead.
    private(set) var signals: [VehicleProfile.StandardSignal] = []

    enum DiscoveryState: Equatable {
        case notRun
        case succeeded
        case failed
    }

    /// PIDs the ECU advertised, and whether asking worked at all.
    private(set) var supportedPIDs: Set<UInt8> = []
    private(set) var discovery: DiscoveryState = .notRun
    /// Which bitmaps actually answered. `supportedPIDs` alone cannot say
    /// whether a missing PID was withheld by the car or never asked about.
    private var discoveryResult = PIDDiscovery()
    private var discoveryRetryDone = false
    /// Discovery state when the manifest was first written. A cold start can
    /// fail here and succeed later, so the stop path records the final result.
    private var discoveryAtRecordingStart: DiscoveryState = .notRun

    /// Module headers for DTC scans. Falls back to the near-universal CAN
    /// engine/transmission pair when a profile does not say.
    private var dtcTargets: [DTCScanner.Target] {
        let modules = profile?.diagnosticModules ?? []
        if modules.isEmpty {
            return [
                DTCScanner.Target(module: "ECM", header: "7E0"),
                DTCScanner.Target(module: "TCM", header: "7E1")
            ]
        }
        return modules.map { DTCScanner.Target(module: $0.name, header: $0.requestHeader) }
    }

    // MARK: - Connection

    private func newConnectionGeneration() -> ConnectionEpoch.Token {
        connectionEpoch.advance()
    }

    private func invalidateConnection() {
        connectionEpoch.advance()
    }

    private func isCurrent(_ generation: ConnectionEpoch.Token) -> Bool {
        connectionEpoch.isValid(generation) && !Task.isCancelled
    }

    func connect() {
        guard phase != .connected, phase != .connecting else { return }
        cancelReconnect()
        intentionalDisconnect = false
        // A manual connect is a new session. While recording, a reconnect is
        // resuming the same car and must keep the resolved profile.
        if !isRecording {
            resetForNewSession()
        }

        transport.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.handleTransportDisconnect(reason) }
        }
        phase = .connecting
        status = "Scanning for adapter…"
        let generation = newConnectionGeneration()
        transportLease.claim(generation)

        pollTask = Task { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            let started = Date()
            connectStartedAt = started
            do {
                let startBegan = Date()
                try await transport.start()
                let startMs = Date().timeIntervalSince(startBegan) * 1000

                // The adapter that worked last time is connected directly; a
                // scan is the fallback, not the default.
                status = "Scanning for adapter…"
                let link = try await connectAdapter(scanSeconds: 8, generation: generation)
                guard self.isCurrent(generation) else { return }
                let candidate = link.candidate
                status = "Configuring adapter…"
                KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)

                let client = ELMClient(transport: transport, logger: nil)
                elm = client
                adapterName = candidate.name.isEmpty ? "OBD adapter" : candidate.name
                let elmBegan = Date()

                _ = try? await client.send("ATE0", timeout: 2)
                _ = try? await client.send("ATL0", timeout: 2)
                _ = try? await client.send("ATS0", timeout: 2)
                _ = try? await client.send("ATH0", timeout: 2)
                // Prefer the profile's protocol, but never trust it blindly: a
                // wrong pin means no data at all, so fall back to auto-detect.
                var protocolAccepted = false
                if let protocolValue = profile?.elmProtocol {
                    _ = try? await client.send("ATSP\(protocolValue)", timeout: 2)
                    protocolAccepted = await ECUResponds(using: client)
                    if !protocolAccepted {
                        _ = try? await client.send("ATSP0", timeout: 3)
                    }
                } else {
                    _ = try? await client.send("ATSP0", timeout: 3)
                }
                let elmMs = Date().timeIntervalSince(elmBegan) * 1000

                if let reply = try? await client.send("ATDPN", timeout: 2) {
                    let number = reply.statusSummary
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !number.isEmpty { detectedProtocolNumber = number }
                }
                guard self.isCurrent(generation) else { return }

                manufacturerServiceAvailable = await detectManufacturerService(using: client)
                guard self.isCurrent(generation) else { return }
                nextIdentificationAt = Date()

                let discoveryStarted = Date()
                await discoverCapabilities(using: client, generation: generation)
                guard self.isCurrent(generation) else { return }
                let capabilityDiscoveryMs = Date().timeIntervalSince(discoveryStarted) * 1000
                rebuildSignalList()

                lastRPM = nil
                battery.reset()
                batteryLogged = false
                batteryReport = nil
                runningSince = nil
                discoveryRetryDone = false
                gapMonitor = DataGapMonitor(threshold: 10)
                lastSampleAt = nil
                firstSampleAt = nil
                didInitialReads = false
                engineStoppedSince = nil

                connectedAt = Date()
                phase = .connected
                status = signals.isEmpty ? "Connected — no supported PIDs found" : "Connected"

                if let protocolName = try? await client.send("ATDP", timeout: 2) {
                    protocolDescription = protocolName.statusSummary
                }
                _ = protocolAccepted

                // Only what the manifest needs before recording. The initial DPF
                // read and trip snapshot wait for the first successful sample:
                // while the ECU is asleep those requests each burn their timeout,
                // which is how a cold start spent half a minute before showing
                // anything.
                let startOdometer = await readOdometer(using: client)
                let ambient = await readAmbient(using: client)
                guard self.isCurrent(generation) else { return }
                odometerKm = startOdometer
                ambientTempC = ambient
                odometerStartKm = startOdometer

                // Recording is automatic: connecting is the intent to record.
                startRecording()
                session.event(.adapterConnected, ["adapter": adapterName])
                // Every field here is a stage duration, so a reader never has to
                // subtract milestones to find the slow one. `totalMs` is the
                // exception, and says so by name.
                session.event(.startupTiming, [
                    "phase": "connected",
                    "startMs": Self.millis(startMs),
                    "adapterDiscoveryMs": Self.millis(link.discoveryMs),
                    "adapterConnectMs": Self.millis(link.connectMs),
                    "adapterRescanned": link.rescanned ? "true" : "false",
                    "elmInitMs": Self.millis(elmMs),
                    "capabilityDiscoveryMs": Self.millis(capabilityDiscoveryMs),
                    "totalMs": Self.millis(Date().timeIntervalSince(started) * 1000)
                ].merging(manufacturerProbeTimings) { current, _ in current })
                startPolling(generation: generation)
            } catch {
                guard self.isCurrent(generation) else { return }
                self.transport.shutdown()
                self.elm = nil
                phase = .failed("\(error)")
                status = "\(error)"
            }
        }
    }

    /// The link dropped on its own: out of range, unplugged, or a module reset.
    /// This is different from the vehicle going quiet, which is normal.
    private func handleTransportDisconnect(_ reason: String) {
        guard !intentionalDisconnect else { return }

        invalidateConnection()
        stallWatchdog?.cancel()
        stallWatchdog = nil
        // If this callback belongs to a link attempt made by the reconnect task,
        // that task has just been invalidated. Its operations still share the
        // BLE transport, so wait for it to finish before replacing it rather
        // than letting two attempts reset the same transport concurrently.
        let interruptedReconnect = reconnectTask
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectGate.interrupt()
        pollTask?.cancel()
        pollTask = nil
        // The scan in progress belongs to the link that just died; resuming it
        // after reconnection would mix two connections into one result.
        scanner = nil
        transportLease.release()
        transport.shutdown()
        elm = nil
        // Capture this before clearing readings: a gap is not ended by the link
        // dropping, and the last genuine answer is what defines its duration.
        lastSampleAt = lastVehicleAnswerAt
        readings.clear()
        dpf = nil
        lastRPM = nil
        // `batteryLogged` and `runningSince` survive a link outage: the engine
        // did not stop because Bluetooth did, and AGENTS.md requires one battery
        // report per engine cycle rather than one per connection.
        supplyVolts = nil

        session.event(.adapterDisconnected, ["reason": reason])

        // The link dropping is usually distance, not a decision. Keep the
        // session open and try to pick it back up.
        if isRecording {
            if let interruptedReconnect {
                reconnectRestartTask?.cancel()
                reconnectRestartTask = Task { [weak self] in
                    _ = await interruptedReconnect.value
                    guard let self, !Task.isCancelled,
                          self.isRecording, !self.intentionalDisconnect
                    else { return }
                    self.reconnectRestartTask = nil
                    if self.reconnectTask == nil {
                        self.beginReconnect()
                    }
                }
            } else if reconnectRestartTask == nil {
                beginReconnect()
            }
        } else {
            phase = .failed("Adapter disconnected: \(reason)")
            status = "Adapter disconnected"
        }
    }

    /// An adapter that is connected, with the stages that got there.
    private struct AdapterConnection {
        let candidate: BLETransport.Candidate
        /// Finding it: a direct retrieval of the remembered adapter, or a scan.
        let discoveryMs: Double
        /// Connecting: services, characteristics, notification subscription.
        let connectMs: Double
        /// True when the remembered adapter failed and a scan was needed.
        let rescanned: Bool
    }

    /// Stops a superseded attempt at the next await boundary.
    ///
    /// Cancellation does not interrupt a BLE call that is already in flight, so
    /// checking only after `connectAdapter()` returns would let a stale attempt
    /// finish its fallback scan and connect after the user disconnected. If no
    /// replacement owns the transport, this attempt shuts down whatever it
    /// opened; if one does, it leaves that connection alone.
    private func checkpoint(_ generation: ConnectionEpoch.Token) throws {
        switch transportLease.checkpoint(generation, isCurrent: isCurrent(generation)) {
        case .proceed:
            return
        case .aborted(let shutdownTransport):
            if shutdownTransport { transport.shutdown() }
            throw CancellationError()
        }
    }

    /// Connect to the remembered adapter, and scan if that does not work.
    ///
    /// A saved peripheral can go stale — CoreBluetooth may hold a dead
    /// reference after an adapter reset, or the identifier may change. Both the
    /// first connection and automatic reconnection go through here so recovery
    /// cannot be weaker than the manual path.
    private func connectAdapter(
        scanSeconds: TimeInterval,
        generation: ConnectionEpoch.Token
    ) async throws -> AdapterConnection {
        try checkpoint(generation)
        let discoveredAt = Date()
        let remembered = try await transport.findAdapter(scanSeconds: scanSeconds, nameFilter: nil)
        try checkpoint(generation)
        let discoveryMs = Date().timeIntervalSince(discoveredAt) * 1000

        let connectStarted = Date()
        var connected = false
        do {
            _ = try await transport.connect(remembered)
            connected = true
        } catch {
            // Whether the failure was the adapter or our own teardown is
            // decided by the checkpoint below, not by the error type.
            connected = false
        }
        // A link that succeeded after cancellation still belongs to nobody.
        try checkpoint(generation)

        if connected {
            return AdapterConnection(
                candidate: remembered,
                discoveryMs: discoveryMs,
                connectMs: Date().timeIntervalSince(connectStarted) * 1000,
                rescanned: false
            )
        }

        // The failed candidate may still own delegate callbacks or a
        // half-open GATT connection. Release it before scanning so the
        // retry cannot inherit that state.
        transport.disconnect()
        let rescanStarted = Date()
        let fresh = try await transport.findAdapter(
            scanSeconds: scanSeconds, nameFilter: nil, preferKnown: false)
        try checkpoint(generation)
        let rescanMs = Date().timeIntervalSince(rescanStarted) * 1000

        let retryStarted = Date()
        _ = try await transport.connect(fresh)
        try checkpoint(generation)
        return AdapterConnection(
            candidate: fresh,
            discoveryMs: discoveryMs + rescanMs,
            connectMs: Date().timeIntervalSince(retryStarted) * 1000,
            rescanned: true
        )
    }

    // MARK: - Reconnection

    /// Retries for the same ten minutes the idle rule allows, then gives up and
    /// finalises. Backs off so a phone in a pocket is not scanning constantly.
    private func beginReconnect() {
        guard reconnectTask == nil else { return }
        phase = .reconnecting
        status = "Reconnecting…"
        let generation = newConnectionGeneration()
        guard reconnectGate.begin(generation) else { return }
        transportLease.claim(generation)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishReconnectTask(generation) }
            guard self.isCurrent(generation) else { return }
            let deadline = Date().addingTimeInterval(600)
            var attempt = 0
            var delay: UInt64 = 2_000_000_000

            while self.isCurrent(generation), Date() < deadline {
                self.reportGapTransition(
                    self.gapMonitor.update(now: Date(), lastSampleAt: self.lastSampleAt))
                attempt += 1
                self.status = "Reconnecting… (attempt \(attempt))"

                do {
                    try await self.transport.start()
                    // The same direct-then-rescan path as the first connection.
                    // A remembered peripheral that has gone stale must not be
                    // retried for ten minutes while the dongle sits there
                    // advertising under a new identity.
                    let link = try await self.connectAdapter(scanSeconds: 6, generation: generation)
                    guard self.isCurrent(generation) else { return }
                    let candidate = link.candidate

                    let client = ELMClient(transport: self.transport, logger: nil)
                    _ = try? await client.send("ATE0", timeout: 2)
                    _ = try? await client.send("ATS0", timeout: 2)
                    _ = try? await client.send("ATH0", timeout: 2)
                    if let protocolValue = self.profile?.elmProtocol {
                        _ = try? await client.send("ATSP\(protocolValue)", timeout: 2)
                    }
                    if let reply = try? await client.send("ATDPN", timeout: 2) {
                        let number = reply.statusSummary
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !number.isEmpty { self.detectedProtocolNumber = number }
                    }
                    guard self.isCurrent(generation) else { return }

                    self.elm = client
                    KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)
                    self.phase = .connected
                    self.connectedAt = Date()
                    // A retry interrupted by the link drop must be allowed to
                    // run on the replacement connection.
                    self.discoveryRetryDone = false
                    self.status = "Connected"
                    self.session.event(.adapterReconnected, [
                        "attempt": String(attempt),
                        "adapter": candidate.name,
                        "adapterDiscoveryMs": Self.millis(link.discoveryMs),
                        "adapterConnectMs": Self.millis(link.connectMs),
                        "adapterRescanned": link.rescanned ? "true" : "false"
                    ])
                    self.startPolling(generation: generation)
                    return
                } catch {
                    guard self.isCurrent(generation) else { return }
                    self.transport.shutdown()
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 10_000_000_000)
                }
            }

            guard self.isCurrent(generation) else { return }
            self.reportGapTransition(gapMonitor.finish(now: Date(), reason: .linkDown))
            self.stopRecording(reason: "reconnect_timeout")
            self.phase = .failed("Adapter disconnected")
            self.status = "Adapter disconnected"
        }
    }

    private func finishReconnectTask(_ generation: ConnectionEpoch.Token) {
        guard reconnectGate.finish(generation) else { return }
        reconnectTask = nil
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectGate.interrupt()
        reconnectRestartTask?.cancel()
        reconnectRestartTask = nil
    }

    enum DisconnectReason: String {
        case user
        case idleTimeout = "idle_timeout"
    }

    func disconnect(reason: DisconnectReason = .user) {
        intentionalDisconnect = true
        invalidateConnection()
        cancelReconnect()
        stallWatchdog?.cancel()
        stallWatchdog = nil
        pollTask?.cancel()
        pollTask = nil

        session.event(.adapterDisconnected, ["reason": reason.rawValue])
        if isRecording {
            stopRecording(reason: reason.rawValue)
        }
        connectedAt = nil

        transportLease.release()
        transport.shutdown()
        elm = nil
        phase = .idle
        status = "Not connected"
        readings.clear()
        dpf = nil
        scanner = nil
        supplyVolts = nil
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        discoveryAtRecordingStart = discovery

        let profileData = profileURL.flatMap { try? Data(contentsOf: $0) }
        let profileHash = profileData.map(ProfileFingerprint.hash(of:))
        let soak = lastSessionEnd.map { Date().timeIntervalSince($0) / 3600 }

        let manifest = SessionManifest(
            sessionID: SessionStore.makeSessionID(),
            startedAt: WallClock.iso(),
            appVersion: Self.appVersion,
            vehicleProfileID: profileID,
            adapterName: adapterName.isEmpty ? nil : adapterName,
            adapterIdentifier: transport.adapterIdentifier.isEmpty ? nil : transport.adapterIdentifier,
            supportedPIDs: discovery == .succeeded
                ? supportedPIDs.sorted().map { String(format: "%02X", $0) }
                : nil,
            capabilityDiscovery: discovery == .succeeded ? "succeeded" : "failed",
            unansweredPIDBases: discoveryResult.unansweredBases.isEmpty
                ? nil
                : discoveryResult.unansweredBases.sorted().map { String(format: "%02X", $0) },
            profileMatch: profileMatchMethod,
            profileHash: profileHash,
            timezoneOffsetSeconds: TimeZone.current.secondsFromGMT(),
            odometerStartKm: odometerStartKm ?? odometerKm,
            ambientTempC: ambientTempC,
            coldSoakHours: soak,
            notes: profileMatchMethod == ProfileResolver.Method.none.rawValue
                ? ["Recording started before vehicle identification completed."]
                : []
        )

        do {
            snapshotGate.reset()
            try session.start(
                manifest: manifest,
                details: ["polledPIDs": signals.map(\.pid).joined(separator: ",")],
                profileData: profileData
            )
            syncRecordingState()
            lastSessionURL = session.directory
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = nil
            exportedSessionID = nil
            notice = nil
        } catch {
            recording = .failed("\(error)")
            notice = "\(error)"
        }
    }

    func stopRecording(reason: String) {
        guard isRecording else {
            recording = .idle
            return
        }
        reportGapTransition(gapMonitor.finish(now: Date(), reason: .recordingStopped))
        if case .ended(let duration, let peak)? = regenDetector.finish(at: Date()) {
            session.event(.regenEnded, [
                "durationSeconds": String(Int(duration)),
                "peakTempC": String(format: "%.0f", peak),
                "truncated": "true"
            ])
        }
        emitCachedSnapshot(phase: "end")
        // Record what discovery actually achieved during the session. Writing
        // only the connect-time result would report "failed" for a cold start
        // that resolved itself once the ECU woke.
        persistDiscoveryIfRecording()
        if discoveryAtRecordingStart != .succeeded, discovery == .succeeded {
            session.appendNote("Capability discovery did not answer at session start and succeeded once the ECU was awake.")
        }
        if !discoveryResult.unansweredBases.isEmpty {
            session.appendNote("Capability discovery left a PID bitmap unanswered, so its range was polled without being checked against the ECU.")
        }
        session.updateProfile(
            id: profileID,
            hash: profileURL.flatMap { try? Data(contentsOf: $0) }
                .map(ProfileFingerprint.hash(of:)),
            match: profileMatchMethod
        )
        if [ProfileResolver.Method.calibration.rawValue,
            ProfileResolver.Method.vin.rawValue].contains(profileMatchMethod),
           manufacturerServiceAvailable, !verificationDone {
            session.appendNote("Profile matched by \(profileMatchMethod) but could not be verified against live data in this session.")
        }
        if profileMatchMethod == ProfileResolver.Method.none.rawValue {
            let reason = profileReason.isEmpty ? "the vehicle could not be identified" : profileReason
            session.appendNote("No vehicle profile applied: \(reason)")
        }
        session.updateOdometer(start: odometerStartKm, end: odometerKm)
        let moduleNames = dtcTargets.map(\.module).joined(separator: ", ")
        if !moduleNames.isEmpty {
            session.appendNote("DTC scans targeted \(moduleNames).")
        }
        if profile?.service.readByLocalIdentifier != nil {
            session.appendNote(manufacturerServiceAvailable
                ? "Manufacturer service 0x21 answered during this session."
                : "Manufacturer service 0x21 did not answer during this session.")
        }
        let result = session.stop(reason: reason)
        lastSessionEnd = Date()
        UserDefaults.standard.set(lastSessionEnd, forKey: "lastSessionEnd")
        syncRecordingState()
        lastSessionURL = session.directory

        if let problem = result.problem {
            notice = "Session saved with problems: \(problem)"
        } else {
            let directory = session.directory
            let samples = directory.map {
                SessionStore.lineCount(at: $0, filename: SessionRecorder.samplesFilename())
            } ?? 0
            notice = samples == 0 ? "Session saved with no samples." : nil
        }
    }

    private func syncRecordingState() {
        switch session.state {
        case .idle: recording = .idle
        case .recording(let id): recording = .recording(sessionID: id)
        case .stopped(let id): recording = .stopped(sessionID: id)
        case .failed(let message): recording = .failed(message)
        }
    }

    /// Called when the app is about to terminate, so a session is not left open.
    func prepareForTermination() {
        guard isRecording else { return }
        reportGapTransition(gapMonitor.finish(now: Date(), reason: .recordingStopped))
        stopRecording(reason: "app_quit")
    }

    func exportLastSession() async {
        guard let directory = lastSessionURL else {
            notice = "No session to export yet."
            return
        }
        do {
            // ZIP creation copies and compresses the whole directory. Keeping it
            // on the main actor blocks the live dashboard for the duration.
            let created = try await Task.detached(priority: .userInitiated) {
                try SessionArchive.export(directory)
            }.value
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = created
            exportedSessionID = directory.lastPathComponent
        } catch {
            notice = "\(error)"
        }
    }

    // MARK: - Battery

    /// Feeds one complete cycle, not one signal at a time.
    ///
    /// Both inputs are optional and belong to the same pass. Passing a cached
    /// RPM beside a fresh crank voltage hides the dip; passing a cached voltage
    /// beside a fresh RPM records a crank minimum from several seconds earlier.
    private func feedBatteryMonitor(volts: Double, rpm: Double?, now: Date = Date()) {
        battery.ingest(VoltageSample(atMs: batteryClock.nowMs(), volts: volts, rpm: rpm))

        // A new start inside one connection is a new cycle. The monitor latches
        // "running", so without this the next crank would never be measured.
        // A stop needs a current rpm to be believed. This car's charging floats
        // between 12.6 and 14.5 V by design, so a voltage dip is not a stop —
        // and treating a missing rpm as zero reported a stop after every
        // sample, resetting the monitor and re-emitting a report every few
        // seconds.
        if battery.currentPhase == .running, let rpm, rpm < 400 {
            if engineStoppedSince == nil { engineStoppedSince = now }
            if let since = engineStoppedSince,
               now.timeIntervalSince(since) > 5,
               batteryLogged {
                battery.reset()
                batteryLogged = false
                runningSince = nil
                engineStoppedSince = nil
            }
        } else {
            engineStoppedSince = nil
        }

        guard battery.currentPhase == .running else { return }
        if runningSince == nil { runningSince = now }

        // Wait for the alternator to settle before reporting: an immediate
        // snapshot has no charging voltage to show.
        guard !batteryLogged,
              let since = runningSince,
              now.timeIntervalSince(since) >= 5,
              battery.chargingSettled
        else { return }

        batteryLogged = true
        let report = battery.report()
        batteryReport = report
        session.event(.batteryTest, report.eventDetails)
    }

    // MARK: - Data gaps

    /// A silent period is recorded, because otherwise a log looks like the
    /// engine did nothing rather than that the app could not reach it.
    private func reportGapTransition(_ transition: DataGapMonitor.Transition?) {
        guard let transition, isRecording else { return }
        switch transition {
        case .started(let quietFor):
            session.event(.dataGap, ["quietSeconds": String(Int(quietFor))])
        case .ended(let gapSeconds, let reason):
            // Only a sample arriving may be called a resumption. A link drop, a
            // stall or a stop close the same gap but say something different
            // about why data stopped.
            if reason == .resumed {
                session.event(.dataResumed, ["gapSeconds": String(Int(gapSeconds))])
            } else {
                session.event(.dataGapEnded, [
                    "gapSeconds": String(Int(gapSeconds)),
                    "reason": reason.rawValue
                ])
            }
        }
    }

    // MARK: - Capability discovery

    private(set) var protocolDescription = ""
    /// `ATDPN` as reported by the adapter, used to choose a valid module header.
    private var detectedProtocolNumber: String?

    private var protocolIdentifier: String? {
        detectedProtocolNumber ?? profile?.transport?.elmProtocol
    }

    /// Standard OBD is normally read by broadcast, but this car has both an ECM
    /// and a TCM answering `7DF`. Taking the first frame then attributes the
    /// transmission's speed or bitmap to the engine. Addressing the profile's
    /// ECM makes the responder unambiguous without enabling headers (which
    /// latches this clone's receive filter).
    ///
    /// A non-CAN bus must keep broadcast: `7E0` is a CAN header, and sending it
    /// to an ISO 9141 or KWP vehicle loses the request rather than selecting an
    /// engine module. The same applies to 29-bit CAN, where the profile's
    /// `7E0` is an 11-bit address; `OBDProtocol.engineHeader` makes that choice
    /// for both standard and manufacturer traffic.
    private var standardHeader: String {
        OBDProtocol.engineHeader(
            profileHeader: profile?.engineRequestHeader,
            protocolIdentifier: protocolIdentifier)
    }

    /// Manufacturer service `0x21` is read from the engine module too. A
    /// profile that names a different ECM header is trusted by the shared
    /// helper; a profile with no ECM keeps the same protocol-aware fallback.
    private var manufacturerHeader: String { standardHeader }

    private func selectEngineHeader(using elm: ELMClient) async {
        _ = try? await elm.send("ATSH\(standardHeader)", timeout: 2)
    }

    private func selectManufacturerHeader(using elm: ELMClient) async {
        _ = try? await elm.send("ATSH\(manufacturerHeader)", timeout: 2)
    }

    private func restoreBroadcastHeader(using elm: ELMClient) async {
        _ = try? await elm.send("ATSH7DF", timeout: 2)
    }

    /// True when the ECU answers a basic request, used to validate a pinned
    /// protocol before trusting it.
    private func ECUResponds(using elm: ELMClient) async -> Bool {
        await selectEngineHeader(using: elm)
        guard let reply = try? await elm.send("0100", timeout: 5),
              let hex = reply.payloadHex, hex.hasPrefix("4100")
        else { return false }
        return true
    }

    /// Asks which PIDs the vehicle supports.
    ///
    /// Each bitmap is trusted only for its own range, so a pass that stops at a
    /// gap leaves the higher ranges unknown rather than unsupported. Retrying
    /// carries the earlier answers in, so a second pass costs one request.
    private func discoverCapabilities(
        using elm: ELMClient,
        into previous: PIDDiscovery = PIDDiscovery(),
        generation: ConnectionEpoch.Token
    ) async {
        guard isCurrent(generation) else { return }
        var result = previous
        await selectEngineHeader(using: elm)
        while let base = result.nextProbe() {
            guard isCurrent(generation) else { return }
            let command = String(format: "01%02X", base)
            let reply = try? await elm.send(command, timeout: 2)
            guard isCurrent(generation) else { return }
            guard let hex = reply?.payloadHex,
                  let supported = PIDCapabilities.supported(fromHex: hex, base: base),
                  !supported.isEmpty
            else {
                // Stop at the first gap. A later retry can fill it; probing
                // above an unanswered bitmap cannot make the pass authoritative.
                break
            }
            // An all-zero bitmap would say "this car supports nothing", which no
            // compliant vehicle does; padding or a truncated read is likelier,
            // so it is treated as no answer rather than as an empty car.
            result.record(base: base, pids: supported)
        }
        guard isCurrent(generation) else { return }
        discoveryResult = result
        supportedPIDs = result.supportedPIDs
        // A pass that answered only a higher bitmap learned nothing usable:
        // without the first one there is no way to tell which PIDs exist.
        discovery = result.isRooted ? .succeeded : .failed
    }

    /// Discovery can improve after the first sample. Persist immediately, not
    /// only at stop: an interrupted session must not keep claiming the cold-start
    /// failure while its samples were collected after the car woke.
    private func persistDiscoveryIfRecording() {
        guard isRecording else { return }
        session.updateDiscovery(
            capabilityDiscovery: discovery == .succeeded ? "succeeded" : "failed",
            supportedPIDs: discovery == .succeeded
                ? supportedPIDs.sorted().map { String(format: "%02X", $0) }
                : nil,
            unansweredPIDBases: discoveryResult.unansweredBases.isEmpty
                ? nil
                : discoveryResult.unansweredBases.sorted().map { String(format: "%02X", $0) }
        )
    }

    /// Profile signals if it has any, otherwise the generic baseline — then
    /// filtered by what the car actually reports.
    private func rebuildSignalList() {
        let base = profile?.signals ?? []
        let chosen = base.isEmpty ? GenericSignals.defaults : base

        guard discovery == .succeeded else {
            // We could not ask, so show what we have rather than nothing.
            signals = chosen
            return
        }

        // Discovery succeeded: trust it, but only for the ranges it reached. A
        // PID the ECU does not advertise is dropped, even if that leaves the
        // dashboard empty — showing tiles that can never populate is worse than
        // an honest empty state. A PID in a range whose bitmap never answered
        // is a different thing: it is unknown, and dropping it is how one
        // missed reply turned a 28-PID car into a 1-PID dashboard.
        signals = chosen.filter { signal in
            guard let pid = signal.pidValue else { return false }
            return discoveryResult.shouldPoll(pid)
        }
    }

    /// A poll loop that has not completed an iteration for a minute is wedged,
    /// whatever command it is inside. Watching the loop rather than one wrapped
    /// call covers discovery, identification, DTC scanning and sweep traffic too.
    func checkForStall(now: Date = Date()) {
        guard phase == .connected, let last = lastLoopTick else { return }
        guard now.timeIntervalSince(last) > 60 else { return }
        recoverFromStall()
    }

    /// A wedged link is not the end of a drive: the session stays open and the
    /// reconnect path picks it up, exactly as it does for a dropped link.
    private func recoverFromStall() {
        notice = "Connection stalled; reconnecting."
        status = "Reconnecting…"
        invalidateConnection()
        stallWatchdog?.cancel()
        stallWatchdog = nil
        pollTask?.cancel()
        pollTask = nil
        lastSampleAt = lastVehicleAnswerAt
        reportGapTransition(gapMonitor.finish(now: Date(), reason: .stalled))
        // A half-finished scan belongs to the connection that died. Carrying it
        // across the reconnect would assemble one result from two buses.
        scanner = nil
        transport.shutdown()
        elm = nil
        lastLoopTick = nil
        readings.clear()
        dpf = nil
        lastRPM = nil
        supplyVolts = nil
        if isRecording {
            beginReconnect()
        } else {
            phase = .failed("Connection stalled")
            status = "Connection stalled"
        }
    }

    /// Called when the app returns to the foreground: iOS may have suspended a
    /// request mid-flight, leaving the loop waiting forever.
    func appDidBecomeActive() {
        checkForStall()
    }

    /// A UI phase, kept free of SwiftUI so this file stays a model.
    enum AppPhase: String {
        case active
        case inactive
        case background
    }

    /// Recorded in the session so a later report of "it froze" can be checked
    /// against the file instead of needing the phone's system log.
    func appDidChangePhase(_ phase: AppPhase, now: Date = Date()) {
        guard isRecording else { return }
        var details = ["phase": phase.rawValue]
        if let last = lastVehicleAnswerAt {
            details["quietSeconds"] = String(Int(now.timeIntervalSince(last).rounded()))
        }
        session.event(.appLifecycle, details)
    }

    // MARK: - Silence

    /// The last genuine vehicle answer. `readings.lastUpdate` is cleared when a
    /// link drops, but `lastSampleAt` deliberately survives.
    private var lastVehicleAnswerAt: Date? {
        VehicleActivity.lastAnswer(lastUpdate: lastUpdate, lastSampleAt: lastSampleAt)
    }

    /// Silence and the idle watchdog use the same reference. A reconnect used
    /// to pass the original `connectedAt` here, which made a five-second outage
    /// after a long drive look fifteen minutes silent and immediately time out.
    private var silenceReference: Date? {
        VehicleActivity.silenceReference(
            lastUpdate: lastUpdate,
            lastSampleAt: lastSampleAt,
            connectedAt: connectedAt)
    }

    /// True while the car — not the adapter — has stopped answering.
    func isVehicleSilent(now: Date = Date()) -> Bool {
        guard isConnected else { return false }
        return silence.isNoticeable(now: now, reference: silenceReference)
    }

    /// One line for the header, or nil while the car is answering.
    ///
    /// The values on screen are the last ones the car gave us. Saying so is the
    /// difference between "the app is broken" and "the car is off".
    func silenceNotice(now: Date = Date()) -> String? {
        guard isVehicleSilent(now: now) else { return nil }
        var parts = ["Vehicle not responding"]
        if let last = lastVehicleAnswerAt {
            parts.append("last reading \(Int(now.timeIntervalSince(last).rounded())) s ago")
        } else {
            parts.append("no reading since connecting")
        }
        if let supplyVolts {
            parts.append(String(format: "%.1f V at the adapter", supplyVolts))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Polling

    private func startPolling(generation: ConnectionEpoch.Token) {
        lastLoopTick = Date()
        pollTask?.cancel()
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                self.checkForStall()
            }
        }

        pollTask = Task { [weak self] in
            guard let self, let elm else { return }

            while self.isCurrent(generation) {
                // The car going quiet is judged on every iteration, from the
                // last sample and not from a success: measuring silence inside
                // the success path always read zero, so a sleeping ECU left no
                // data_gap in the log and looked like a frozen app.
                reportGapTransition(gapMonitor.update(
                    now: Date(),
                    lastSampleAt: lastVehicleAnswerAt))

                let quiet = silence.shouldPollQuietly(
                    now: Date(), reference: silenceReference)

                if quiet {
                    await quietCycle(using: elm, generation: generation)
                } else {
                    await sampleCycle(using: elm, generation: generation)
                }
                guard self.isCurrent(generation) else { return }

                lastLoopTick = Date()

                if case .failed = recording {
                    // A write failure has stopped the session; keep sampling for
                    // the UI but stop pretending we are recording.
                    syncRecordingState()
                }

                if quiet {
                    // A sleeping vehicle will not start answering because we ask
                    // faster, and every request in the full cycle is one that
                    // cannot be answered.
                    try? await Task.sleep(
                        nanoseconds: UInt64(silence.quietInterval * 1_000_000_000))
                } else if let last = lastVehicleAnswerAt, Date().timeIntervalSince(last) > 5 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                if let connectedAt,
                   watchdog.shouldDisconnect(
                       now: Date(),
                       lastActivity: lastVehicleAnswerAt,
                       connectedAt: connectedAt) {
                    disconnect(reason: .idleTimeout)
                    return
                }

            }
        }
    }

    /// One full pass: every live signal, then the periodic extra work.
    private func sampleCycle(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        // Address the engine module rather than taking the first frame from a
        // broadcast: the TCM answers the same request on this car and its speed
        // or bitmap would otherwise be attributed to the engine.
        await selectEngineHeader(using: elm)

        // Keep this cycle's observations together. The battery monitor must not
        // combine a fresh voltage with an RPM cached from an earlier cycle, or a
        // crank where one read timed out is graded from stale data.
        var batteryCycle = BatteryCycle()
        for signal in signals {
            guard isCurrent(generation) else { return }
            let value = await sample(signal, using: elm, generation: generation)
            if let pid = signal.pidValue {
                batteryCycle.record(pid: pid, value: value)
            }
        }

        // A crank lasts one to two seconds. While the engine is off — or when
        // this cycle's RPM read failed — sample voltage a second time so the dip
        // is caught.
        if batteryCycle.rpm.map({ $0 < 400 }) ?? true,
           let voltage = signals.first(where: { $0.pid == "42" }) {
            guard isCurrent(generation) else { return }
            let value = await sample(voltage, using: elm, generation: generation)
            batteryCycle.record(pid: 0x42, value: value)
        }

        if let sample = batteryCycle.voltageSample {
            feedBatteryMonitor(volts: sample.volts, rpm: sample.rpm)
        }

        if isRecording,
           Date().timeIntervalSince(lastOdometerRead) > 60 {
            // Only a successful read resets the clock. Stamping the attempt
            // regardless meant a cold ECU that answered a moment later was not
            // read again for a minute, and the start odometer could be lost for
            // the whole session.
            let reading = await readOdometer(using: elm)
            guard isCurrent(generation) else { return }
            if let reading {
                lastOdometerRead = Date()
                recordOdometer(reading)
            } else if Date().timeIntervalSince(lastOdometerRead) > 300 {
                // A car that never answers stops being asked every cycle.
                lastOdometerRead = Date()
            }
        }

        guard isCurrent(generation) else { return }
        if identificationIsDue() {
            await attemptIdentification(using: elm, generation: generation)
        }
        guard isCurrent(generation) else { return }
        if (lastRPM ?? 0) > 400, !verificationDone,
           [ProfileResolver.Method.calibration.rawValue,
            ProfileResolver.Method.vin.rawValue].contains(profileMatchMethod) {
            await verifyResolvedProfile(using: elm, generation: generation)
        }

        guard isCurrent(generation) else { return }
        await stepDTCScan(using: elm, generation: generation)

        guard isCurrent(generation) else { return }
        await stepPriorityScan(using: elm, generation: generation)

        guard isCurrent(generation) else { return }
        await stepProfileScan(using: elm, generation: generation)

        // One-time enrichment, once the bus is actually answering. Doing
        // this before polling was what delayed the first live reading.
        if !didInitialReads, isRecording, let firstSampleAt {
            didInitialReads = true
            // Measure the metric this event promises before enrichment adds
            // DPF and trip-snapshot round trips.
            if let connectStartedAt {
                session.event(.startupTiming, [
                    "phase": "first_sample",
                    "sinceConnectMs": Self.millis(
                        firstSampleAt.timeIntervalSince(connectStartedAt) * 1000)
                ])
            }
            await captureTripSnapshot(phase: "start", using: elm, generation: generation)
        }
    }

    /// One gentle exchange while the car is asleep.
    ///
    /// The adapter's own supply voltage still works with the ignition off, so it
    /// is read for the display. Engine speed is then asked of the ECU: the reply
    /// to a real PID is what proves the car has woken, and a successful read
    /// returns the loop to the full cycle by itself. Without that probe, quiet
    /// mode would be a one-way door.
    private func quietCycle(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        // The sweep may have left a module header selected.
        await selectEngineHeader(using: elm)

        if let reply = try? await elm.send("ATRV", timeout: 2) {
            guard isCurrent(generation) else { return }
            supplyVolts = reply.supplyVolts
        }

        // Engine speed is the best wake probe, but a profile without it (or an
        // authoritative bitmap that omitted it) must still ask the ECU
        // something. Returning here made quiet mode a one-way door.
        if let probe = QuietProbe.choose(from: signals) {
            await sample(probe, using: elm, generation: generation)
            return
        }

        let reply = try? await elm.send("0100", timeout: 2)
        guard isCurrent(generation) else { return }
        guard let hex = reply?.payloadHex, hex.hasPrefix("4100") else { return }
        // The car answered even though no numeric signal is available. This is
        // a genuine resumption, not a link drop.
        noteSample()
    }

    /// One live signal. A failed read writes nothing: absence is meaningful.
    /// Records that the vehicle actually answered. This is the only path that
    /// may close a data gap as `data_resumed`.
    private func noteSample(at date: Date = Date()) {
        if firstSampleAt == nil { firstSampleAt = date }
        lastSampleAt = date
        reportGapTransition(gapMonitor.update(now: date, lastSampleAt: date))
    }

    @discardableResult
    private func sample(
        _ signal: VehicleProfile.StandardSignal,
        using elm: ELMClient,
        generation: ConnectionEpoch.Token
    ) async -> Double? {
        guard let pid = signal.pidValue else { return nil }
        let command = String(format: "01%02X", pid)
        guard let reply = try? await elm.send(command, timeout: 2),
              let hex = reply.payloadHex,
              hex.hasPrefix(String(format: "41%02X", pid)),
              let data = LiveModel.bytes(String(hex.dropFirst(4))),
              let value = signal.decode(data)
        else { return nil }
        guard isCurrent(generation) else { return nil }

        let sampleTime = Date()
        readings.setStandard(pid: signal.pid, value: value, at: sampleTime)
        noteSample(at: sampleTime)

        // These caches are used for control flow, not as battery evidence.
        // Battery classification receives this cycle's values explicitly.
        if pid == 0x0C { lastRPM = value }

        // The ECU may have been asleep when we probed. Now that it is answering,
        // ask again so an unnecessary empty capability set is not recorded —
        // including a pass that lost a bitmap to the wake.
        if discoveryResult.needsRetry, !discoveryRetryDone {
            discoveryRetryDone = true
            await discoverCapabilities(using: elm, into: discoveryResult, generation: generation)
            guard isCurrent(generation) else { return nil }
            rebuildSignalList()
            persistDiscoveryIfRecording()
        }

        if isRecording {
            let written = session.sample(
                pid: pid,
                name: signal.name,
                value: value,
                unit: signal.unit,
                raw: hex
            )
            if !written { syncRecordingState() }
        }
        return value
    }

    // MARK: - DTC scanning

    /// One scanner request per loop, with the target header selected immediately
    /// before it. The header must not be assumed to persist: live sampling
    /// resets addressing between steps.
    private func stepDTCScan(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        if scanner == nil {
            guard Date().timeIntervalSince(lastDTCStep) >= dtcScanInterval else { return }
            let targets = dtcTargets
            guard !targets.isEmpty else { return }
            scanner = DTCScanner(targets: targets)
            lastDTCStep = Date()
        }
        guard var active = scanner else { return }

        switch active.next() {
        case .finished:
            scanner = nil
            completeScan(active.diagnostics, outcomes: active.outcomeDetails)
        case .request(let request):
            // Only query once the adapter has acknowledged the header. Sending
            // anyway could get an answer from the wrong module and attribute it
            // to this one.
            let headerReply = try? await elm.send("ATSH" + request.header, timeout: 2)
            // Cancellation during the wait means the link is gone and the scan
            // is being abandoned. Committing the step anyway would leave a
            // partial result to be resumed after reconnection.
            guard isCurrent(generation) else { return }
            guard headerReply?.isOK == true else {
                active.ingestHeaderFailure()
                scanner = active
                return
            }
            let reply = try? await elm.send(request.command, timeout: 3)
            guard isCurrent(generation) else { return }
            active.ingest(responseHex: reply?.payloadHex)
            scanner = active
        }
    }

    func completeScan(_ diagnostics: VehicleDiagnostics, outcomes: [String: String]) {
        self.diagnostics = diagnostics
        self.diagnosticsAt = Date()

        let signature = DTCSnapshot.signature(diagnostics, outcomes: outcomes)
        guard snapshotGate.shouldEmit(signature) else { return }

        var details: [String: String] = [
            "complete": diagnostics.isComplete ? "true" : "false",
            "summary": diagnostics.headline
        ]
        if !diagnostics.modulesIncomplete.isEmpty {
            details["incompleteModules"] = diagnostics.modulesIncomplete.joined(separator: ",")
        }
        for module in diagnostics.modules {
            details["\(module.module).stored"] = module.stored?.joined(separator: ",") ?? ""
            details["\(module.module).pending"] = module.pending?.joined(separator: ",") ?? ""
            details["\(module.module).permanent"] = module.permanent?.joined(separator: ",") ?? ""
            details["\(module.module).complete"] = module.isComplete ? "true" : "false"
        }
        for (key, value) in outcomes {
            details["outcome.\(key)"] = value
        }

        session.event(.dtcSnapshot, details)
    }

    // MARK: - Manufacturer data

    /// Live blocks refreshed every cycle, as declared by the vehicle profile.
    private func stepPriorityScan(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        guard let profile, !profile.priorityLIDs.isEmpty else { return }
        for lid in profile.priorityLIDs {
            guard isCurrent(generation) else { return }
            await selectManufacturerHeader(using: elm)
            guard isCurrent(generation) else { return }
            let command = String(format: "21%02X", lid)
            let reply = try? await elm.send(command, timeout: 3)
            guard isCurrent(generation) else { return }
            guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else { continue }

            manufacturerServiceAvailable = true
            let decodedValues = profile.decode(frame)
            let sampleTime = Date()
            for decoded in decodedValues {
                readings.setManufacturer(decoded, at: sampleTime)
                if isRecording {
                    let written = session.manufacturerSample(
                        lid: decoded.lid,
                        itemNumber: decoded.itemNumber,
                        name: decoded.name,
                        value: decoded.value,
                        unit: decoded.unit,
                        raw: hex
                    )
                    if !written { syncRecordingState() }
                }
            }
            if !decodedValues.isEmpty { noteSample(at: sampleTime) }
            if let temperature = profile.roles?.dpfTemperature?.value(in: decodedValues) {
                trackRegeneration(dpfTemperature: temperature)
            }
            refreshDPFSummary()
        }
    }

    /// One local identifier per loop, so 76 blocks refresh in the background
    /// without blocking live sampling.
    private func stepProfileScan(using elm: ELMClient, generation: ConnectionEpoch.Token) async {
        guard let profile, !profile.localIdentifiers.isEmpty else { return }
        // Defensive: a profile change must never let an old plan outlive it.
        if sweep.planned != profile.localIdentifiers {
            sweep = SweepPass(planned: profile.localIdentifiers)
        }
        guard let step = sweep.next() else { return }

        var reachedOutcome = false
        // A connection lost before the request is sent leaves this identifier
        // unattempted, and one lost mid-request must not close the cycle with
        // an outcome that was never observed.
        defer { if !reachedOutcome { sweep.abandon() } }

        guard isCurrent(generation) else { return }
        await selectManufacturerHeader(using: elm)
        guard isCurrent(generation) else { return }

        let command = String(format: "21%02X", step.lid)
        // Recorded immediately before the request: from here a timeout is
        // still an attempt, but configuring the header is not.
        sweep.requestSent(step.lid)
        let reply = try? await elm.send(command, timeout: 3)
        guard isCurrent(generation) else { return }

        let hex = reply?.payloadHex
        let frame = hex.flatMap { MUT21Frame(hex: $0) }
        reachedOutcome = true
        if let summary = sweep.finished(step.lid, answered: frame != nil) {
            session.event(.sweepCompleted, [
                "cycle": String(summary.cycle),
                "attempted": String(summary.attempted),
                "answered": String(summary.answered),
                "missing": summary.missing.map { String(format: "%02X", $0) }.joined(separator: ",")
            ])
        }

        guard let frame, let hex else { return }

        // A parsed `0x21` frame is proof the manufacturer service works, which
        // one connect-time probe is not: the probe can lose the race with a
        // waking ECU, and a manifest written from it alone can claim the
        // service never answered while the samples above say otherwise.
        manufacturerServiceAvailable = true
        let decodedValues = profile.decode(frame)
        let sampleTime = Date()

        for decoded in decodedValues {
            readings.setManufacturer(decoded, at: sampleTime)
            if isRecording {
                let written = session.manufacturerSample(
                    lid: decoded.lid,
                    itemNumber: decoded.itemNumber,
                    name: decoded.name,
                    value: decoded.value,
                    unit: decoded.unit,
                    raw: hex
                )
                if !written { syncRecordingState() }
            }
        }
        if !decodedValues.isEmpty { noteSample(at: sampleTime) }
        refreshDPFSummary()
    }

    /// Everything a future comparison needs, captured once at each end of a
    /// session so regen interval and soot-per-km become measurable rather than
    /// inferred.
    private func captureTripSnapshot(
        phase: String,
        using elm: ELMClient,
        generation: ConnectionEpoch.Token
    ) async {
        guard let profile else { return }
        var details: [String: String] = ["phase": phase]

        for lid in profile.tripSnapshotLIDs {
            guard isCurrent(generation) else { return }
            await selectManufacturerHeader(using: elm)
            guard isCurrent(generation) else { return }
            guard let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
                  let hex = reply.payloadHex,
                  let frame = MUT21Frame(hex: hex)
            else { continue }
            manufacturerServiceAvailable = true
            for value in profile.decode(frame) {
                let key = value.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: ".", with: "")
                details[String(format: "%02X.%@", lid, key)] = String(format: "%.2f", value.value)
            }
        }
        await restoreBroadcastHeader(using: elm)
        guard isCurrent(generation) else { return }

        if let odometerKm { details["odometerKm"] = String(odometerKm) }
        if let ambientTempC { details["ambientTempC"] = String(format: "%.1f", ambientTempC) }
        session.event(.tripSnapshot, details)
    }

    /// End-of-session snapshot without new I/O. The live block is refreshed
    /// every cycle, so these values are at most a second or two old.
    private func emitCachedSnapshot(phase: String) {
        guard !manufacturer.isEmpty else { return }
        var details: [String: String] = ["phase": phase, "source": "cached"]

        for value in manufacturer.values {
            let key = value.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: ".", with: "")
            details[String(format: "%02X.%@", value.lid, key)] = String(format: "%.2f", value.value)
        }
        if let odometerKm { details["odometerKm"] = String(odometerKm) }
        session.event(.tripSnapshot, details)
    }

    /// Odometer from the profile's declared odometer role. Needed because
    /// regeneration interval and soot-per-km are otherwise not computable.
    private func readOdometer(using elm: ELMClient) async -> Int? {
        guard let profile,
              let role = profile.roles?.odometer,
              let lid = role.lidValue
        else { return nil }
        guard !Task.isCancelled else { return nil }
        await selectManufacturerHeader(using: elm)
        guard !Task.isCancelled else { return nil }
        let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 2)
        guard !Task.isCancelled else { return nil }
        await restoreBroadcastHeader(using: elm)
        guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else { return nil }
        // The service answered, whatever the connect-time probe concluded.
        manufacturerServiceAvailable = true
        return role.value(in: profile.decode(frame)).map(Int.init)
    }

    /// Records an odometer reading and, the first time one arrives, writes it
    /// to the manifest as the session's start. Soot per kilometre and the
    /// regeneration interval both need a start value, and they are useless with
    /// an end value alone.
    private func recordOdometer(_ reading: Int) {
        odometerKm = reading
        guard isRecording, odometerStartKm == nil else { return }
        odometerStartKm = reading
        session.updateOdometer(start: reading)
    }

    /// Intake air temperature with the engine off, as an ambient proxy: this ECU
    /// has no ambient-temperature PID.
    private func readAmbient(using elm: ELMClient) async -> Double? {
        await selectEngineHeader(using: elm)
        let reply = try? await elm.send("010F", timeout: 2)
        await restoreBroadcastHeader(using: elm)
        guard let hex = reply?.payloadHex, hex.hasPrefix("410F"),
              let bytes = LiveModel.bytes(String(hex.dropFirst(4))),
              let first = bytes.first
        else { return nil }
        return Double(first) - 40
    }

    /// Rebuilds the DPF summary from profile-decoded live values.
    ///
    /// This replaced a second, hard-coded decoder. A profile without DPF roles
    /// simply shows no DPF summary.
    private func refreshDPFSummary() {
        guard let roles = profile?.roles else {
            dpf = nil
            return
        }
        let sootByAccumulation = roles.sootByAccumulation?
            .value(in: manufacturer.values)
        let sootByPressure = roles.sootByPressure?
            .value(in: manufacturer.values)
        let count = roles.regenerationCount?.value(in: manufacturer.values)
        let mode: RegenerationMode? = roles.regenerationMode?
            .value(in: manufacturer.values)
            .map { $0 == 0 ? .notRequested : .unknown(raw: Int($0)) }

        guard sootByAccumulation != nil || sootByPressure != nil
                || count != nil || mode != nil
        else {
            dpf = nil
            return
        }
        dpf = DPFStatus(
            sootByAccumulation: sootByAccumulation,
            sootByPressure: sootByPressure,
            regenerationCount: count.map(Int.init),
            regenerationMode: mode
        )
    }

    /// Regeneration is detected from the filter temperature rather than the ECU's
    /// flag: the temperature lives in the live block at several Hz, while the flag
    /// block refreshes once a minute and a half.
    private func trackRegeneration(dpfTemperature: Double) {
        switch regenDetector.ingest(tempC: dpfTemperature, at: Date()) {
        case .started(let temp):
            regenSootAtStart = profile?.roles?.sootByAccumulation?
                .value(in: manufacturer.values)
            var details: [String: String] = ["dpfTempC": String(format: "%.0f", temp)]
            if let soot = regenSootAtStart { details["sootBeforeGL"] = String(format: "%.2f", soot) }
            if let odometerKm { details["odometerKm"] = String(odometerKm) }
            session.event(.regenStarted, details)

        case .ended(let duration, let peak):
            var details: [String: String] = [
                "durationSeconds": String(Int(duration)),
                "peakTempC": String(format: "%.0f", peak)
            ]
            if let soot = regenSootAtStart { details["sootBeforeGL"] = String(format: "%.2f", soot) }
            if let after = profile?.roles?.sootByAccumulation?
                .value(in: manufacturer.values) {
                details["sootAfterGL"] = String(format: "%.2f", after)
            }
            if let before = regenSootAtStart {
                details["sootBurnedGL"] = String(format: "%.2f", max(0, before - (Double(details["sootAfterGL"] ?? "") ?? before)))
            }
            session.event(.regenEnded, details)
            regenSootAtStart = nil

        case nil:
            break
        }
    }

    // MARK: - DPF

    /// The DPF summary is derived from the profile-decoded live block below.
    /// There is deliberately no second, hard-coded Outlander decoder here.

    // MARK: - Helpers

    private static func millis(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// Shown in the UI so a screenshot identifies the build.
    var versionDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "OBDLogger \(version)"
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
