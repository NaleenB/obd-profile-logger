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
    private var lastVolts: Double?
    private var lastRPM: Double?
    private(set) var batteryReport: BatteryReport?
    private var batteryLogged = false
    private var runningSince: Date?
    private var gapMonitor = DataGapMonitor(threshold: 10)
    private var identity = VehicleIdentity()
    private var identityResolved = false
    private var odometerKm: Int?
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
    private var connectedAt: Date?
    /// Decides when silence becomes a message and when it becomes a cheaper loop.
    private let silence = SilenceWatchdog()
    /// Voltage at the adapter, readable with the ignition off. Only meaningful
    /// as a fallback: while the ECU answers, PID `42` is the real measurement.
    private(set) var supplyVolts: Double?

    private var scanner: DTCScanner?
    private var snapshotGate = DTCSnapshotGate()
    private var profileIndex = 0
    private var sweep = SweepAccountant()
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
    private func attemptIdentification(using elm: ELMClient) async {
        guard overrideProfileID == nil,
              profileMatchMethod == ProfileResolver.Method.none.rawValue else { return }

        // The service probe is only meaningful while the ECU is awake. A car
        // that was asleep at connect can start answering later, and without
        // this re-check the agreement route would stay unavailable.
        if !manufacturerServiceAvailable {
            manufacturerServiceAvailable = await detectManufacturerService(using: elm)
        }
        if !identityResolved {
            identity = await readIdentity(using: elm)
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
            if let value = await readStandard(pid, using: elm) {
                standard[pid] = value
            }
        }

        let probeLIDs = Set(candidateProfiles.compactMap(\.identity).flatMap(\.lidValues))
        guard !probeLIDs.isEmpty else { return (standard, decoded) }

        var frames: [UInt8: MUT21Frame] = [:]
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        for lid in probeLIDs.sorted() {
            if let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
               let hex = reply.payloadHex,
               let frame = MUT21Frame(hex: hex) {
                frames[lid] = frame
            }
        }
        _ = try? await elm.send("ATSH7DF", timeout: 2)

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
    private func apply(_ resolution: ProfileResolver.Resolution) {
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
        profileIndex = 0
        sweep = SweepAccountant()
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
        guard let reply = try? await elm.send(String(format: "01%02X", pid), timeout: 2),
              let hex = reply.payloadHex,
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
    private func verifyResolvedProfile(using elm: ELMClient) async {
        guard !verificationDone,
              manufacturerServiceAvailable,
              let profile, let spec = profile.identity,
              let rpm = lastRPM, rpm > 400,
              Date().timeIntervalSince(lastVerificationAttempt) >= 30
        else { return }
        lastVerificationAttempt = Date()

        var standard: [UInt8: Double] = [0x0C: rpm]
        if let coolant = await readStandard(0x05, using: elm) {
            standard[0x05] = coolant
        }

        var values: [Int: Double] = [:]
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        for lid in spec.lidValues {
            if let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
               let hex = reply.payloadHex,
               let frame = MUT21Frame(hex: hex) {
                for value in profile.decode(frame) {
                    if let item = value.itemNumber { values[item] = value.value }
                }
            }
        }
        _ = try? await elm.send("ATSH7DF", timeout: 2)

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
        if let reply = try? await elm.send("0902", timeout: 5), let hex = reply.payloadHex {
            identity.vin = VehicleIdentityDecoder.vin(fromHex: hex)
        }
        if let reply = try? await elm.send("0904", timeout: 5), let hex = reply.payloadHex {
            identity.calibrationID = VehicleIdentityDecoder.calibrationID(fromHex: hex)
        }
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
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        timings["selectHeaderMs"] = Self.millis(Date().timeIntervalSince(headerStart) * 1000)

        let replyStart = Date()
        let reply = try? await elm.send("2111", timeout: 3)
        timings["mutReplyMs"] = Self.millis(Date().timeIntervalSince(replyStart) * 1000)

        let restoreStart = Date()
        _ = try? await elm.send("ATSH7DF", timeout: 2)
        timings["restoreHeaderMs"] = Self.millis(Date().timeIntervalSince(restoreStart) * 1000)

        timings["probeTotalMs"] = Self.millis(Date().timeIntervalSince(probeStart) * 1000)
        manufacturerProbeTimings = timings

        guard let hex = reply?.payloadHex else { return false }
        return hex.hasPrefix("6111")
    }

    /// Profile ids are dotted and human-readable; bundle resources are the short
    /// file names.
    private func resourceName(for id: String) -> String {
        switch id {
        case "mitsubishi-outlander-2016-4n14": return "outlander-2016-4n14"
        case "generic-iso15765-can": return "iso15765-can"
        default: return id
        }
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

    func connect() {
        guard phase != .connected, phase != .connecting else { return }
        cancelReconnect()
        intentionalDisconnect = false

        transport.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.handleTransportDisconnect(reason) }
        }
        phase = .connecting
        status = "Scanning for adapter…"

        pollTask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            connectStartedAt = started
            do {
                try await transport.start()
                let bluetoothMs = Date().timeIntervalSince(started) * 1000

                // The adapter that worked last time is connected directly; a
                // scan is the fallback, not the default.
                var candidate = try await transport.findAdapter(scanSeconds: 8, nameFilter: nil)
                let adapterMs = Date().timeIntervalSince(started) * 1000
                status = "Connecting to \(candidate.name.isEmpty ? "adapter" : candidate.name)…"

                var port: SerialPort
                do {
                    port = try await transport.connect(candidate)
                } catch {
                    // A remembered peripheral can go stale; rescan once.
                    candidate = try await transport.findAdapter(
                        scanSeconds: 6, nameFilter: nil, preferKnown: false)
                    port = try await transport.connect(candidate)
                }
                _ = port
                KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)
                let bleMs = Date().timeIntervalSince(started) * 1000

                let client = ELMClient(transport: transport, logger: nil)
                elm = client
                adapterName = candidate.name.isEmpty ? "OBD adapter" : candidate.name

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
                let elmMs = Date().timeIntervalSince(started) * 1000

                manufacturerServiceAvailable = await detectManufacturerService(using: client)
                identity = VehicleIdentity()
                identityResolved = false
                identificationAttempts = 0
                identificationExhausted = false
                verificationDone = false
                lastVerificationAttempt = .distantPast
                profileReason = ""
                nextIdentificationAt = Date()

                let discoveryStarted = Date()
                await discoverCapabilities(using: client)
                let discoveryMs = Date().timeIntervalSince(discoveryStarted) * 1000
                rebuildSignalList()

                lastVolts = nil
                lastRPM = nil
                battery.reset()
                batteryLogged = false
                batteryReport = nil
                runningSince = nil
                discoveryRetryDone = false
                gapMonitor = DataGapMonitor(threshold: 10)
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
                odometerKm = await readOdometer(using: client)
                ambientTempC = await readAmbient(using: client)

                // Recording is automatic: connecting is the intent to record.
                startRecording()
                session.event(.adapterConnected, ["adapter": adapterName])
                session.event(.startupTiming, [
                    "phase": "connected",
                    "bluetoothMs": Self.millis(bluetoothMs),
                    "adapterMs": Self.millis(adapterMs),
                    "bleMs": Self.millis(bleMs),
                    "elmMs": Self.millis(elmMs),
                    "discoveryMs": Self.millis(discoveryMs),
                    "totalMs": Self.millis(Date().timeIntervalSince(started) * 1000)
                ].merging(manufacturerProbeTimings) { current, _ in current })
                startPolling()
            } catch {
                phase = .failed("\(error)")
                status = "\(error)"
            }
        }
    }

    /// The link dropped on its own: out of range, unplugged, or a module reset.
    /// This is different from the vehicle going quiet, which is normal.
    private func handleTransportDisconnect(_ reason: String) {
        guard !intentionalDisconnect else { return }

        pollTask?.cancel()
        pollTask = nil
        transport.shutdown()
        elm = nil
        readings.clear()
        dpf = nil
        lastRPM = nil
        lastVolts = nil
        batteryLogged = false
        runningSince = nil
        supplyVolts = nil

        session.event(.adapterDisconnected, ["reason": reason])
        reportGapTransition(gapMonitor.finish(now: Date()))

        // The link dropping is usually distance, not a decision. Keep the
        // session open and try to pick it back up.
        if isRecording {
            beginReconnect()
        } else {
            phase = .failed("Adapter disconnected: \(reason)")
            status = "Adapter disconnected"
        }
    }

    // MARK: - Reconnection

    /// Retries for the same ten minutes the idle rule allows, then gives up and
    /// finalises. Backs off so a phone in a pocket is not scanning constantly.
    private func beginReconnect() {
        guard reconnectTask == nil else { return }
        phase = .reconnecting
        status = "Reconnecting…"

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(600)
            var attempt = 0
            var delay: UInt64 = 2_000_000_000

            while !Task.isCancelled, Date() < deadline {
                attempt += 1
                self.status = "Reconnecting… (attempt \(attempt))"

                do {
                    try await self.transport.start()
                    let candidate = try await self.transport.findAdapter(scanSeconds: 6, nameFilter: nil)
                    let port = try await self.transport.connect(candidate)
                    _ = port

                    let client = ELMClient(transport: self.transport, logger: nil)
                    _ = try? await client.send("ATE0", timeout: 2)
                    _ = try? await client.send("ATS0", timeout: 2)
                    _ = try? await client.send("ATH0", timeout: 2)
                    if let protocolValue = self.profile?.elmProtocol {
                        _ = try? await client.send("ATSP\(protocolValue)", timeout: 2)
                    }

                    self.elm = client
                    KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)
                    self.phase = .connected
                    self.status = "Connected"
                    self.session.event(.adapterReconnected, [
                        "attempt": String(attempt),
                        "adapter": candidate.name
                    ])
                    self.gapMonitor = DataGapMonitor(threshold: 10)
                    self.startPolling()
                    self.reconnectTask = nil
                    return
                } catch {
                    self.transport.shutdown()
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 10_000_000_000)
                }
            }

            guard !Task.isCancelled else { return }
            self.stopRecording(reason: "reconnect_timeout")
            self.phase = .failed("Adapter disconnected")
            self.status = "Adapter disconnected"
            self.reconnectTask = nil
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    enum DisconnectReason: String {
        case user
        case idleTimeout = "idle_timeout"
    }

    func disconnect(reason: DisconnectReason = .user) {
        intentionalDisconnect = true
        cancelReconnect()
        pollTask?.cancel()
        pollTask = nil

        session.event(.adapterDisconnected, ["reason": reason.rawValue])
        if isRecording {
            reportGapTransition(gapMonitor.finish(now: Date()))
            stopRecording(reason: reason.rawValue)
        }
        connectedAt = nil

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
            profileMatch: profileMatchMethod,
            profileHash: profileHash,
            timezoneOffsetSeconds: TimeZone.current.secondsFromGMT(),
            odometerStartKm: odometerKm,
            ambientTempC: ambientTempC,
            coldSoakHours: soak,
            notes: [
                "Standard PIDs plus service 0x21 manufacturer observations.",
                "DTC scans cover the engine (7E0) and transmission (7E1) only."
            ]
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
        reportGapTransition(gapMonitor.finish(now: Date()))
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
        session.updateDiscovery(
            capabilityDiscovery: discovery == .succeeded ? "succeeded" : "failed",
            supportedPIDs: discovery == .succeeded
                ? supportedPIDs.sorted().map { String(format: "%02X", $0) }
                : nil
        )
        if discoveryAtRecordingStart != .succeeded, discovery == .succeeded {
            session.appendNote("Capability discovery did not answer at session start and succeeded once the ECU was awake.")
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
        session.updateOdometer(end: odometerKm)
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
        reportGapTransition(gapMonitor.finish(now: Date()))
        stopRecording(reason: "app_quit")
    }

    func exportLastSession() {
        guard let directory = lastSessionURL else {
            notice = "No session to export yet."
            return
        }
        do {
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = try SessionArchive.export(directory)
            exportedSessionID = directory.lastPathComponent
        } catch {
            notice = "\(error)"
        }
    }

    // MARK: - Battery

    private func feedBatteryMonitor(pid: UInt8, value: Double) {
        switch pid {
        case 0x42: lastVolts = value
        case 0x0C: lastRPM = value
        default: return
        }
        guard let volts = lastVolts else { return }

        battery.ingest(VoltageSample(atMs: batteryClock.nowMs(), volts: volts, rpm: lastRPM))

        // A new start inside one connection is a new cycle. The monitor latches
        // "running", so without this the next crank would never be measured.
        if battery.currentPhase == .running, (lastRPM ?? 0) < 400 {
            if engineStoppedSince == nil { engineStoppedSince = Date() }
            if let since = engineStoppedSince,
               Date().timeIntervalSince(since) > 5,
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
        if runningSince == nil { runningSince = Date() }

        // Wait for the alternator to settle before reporting: an immediate
        // snapshot has no charging voltage to show.
        guard !batteryLogged,
              let since = runningSince,
              Date().timeIntervalSince(since) >= 5,
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
        case .ended(let gapSeconds):
            session.event(.dataResumed, ["gapSeconds": String(Int(gapSeconds))])
        }
    }

    // MARK: - Capability discovery

    private(set) var protocolDescription = ""

    /// True when the ECU answers a basic request, used to validate a pinned
    /// protocol before trusting it.
    private func ECUResponds(using elm: ELMClient) async -> Bool {
        guard let reply = try? await elm.send("0100", timeout: 5),
              let hex = reply.payloadHex, hex.hasPrefix("4100")
        else { return false }
        return true
    }

    /// Asks which PIDs the vehicle supports. Purely additive: if every probe
    /// fails, `supportedPIDs` stays empty and nothing is filtered.
    private func discoverCapabilities(using elm: ELMClient) async {
        var found: Set<UInt8> = []
        for base in PIDCapabilities.probePIDs {
            let command = String(format: "01%02X", base)
            guard let reply = try? await elm.send(command, timeout: 2),
                  let hex = reply.payloadHex,
                  let supported = PIDCapabilities.supported(fromHex: hex, base: base)
            else { continue }
            found.formUnion(supported)
            if supported.isEmpty { break }
        }
        supportedPIDs = found
        // A valid bitmap always advertises at least one PID, so an empty result
        // means every probe failed rather than "this car supports nothing".
        discovery = found.isEmpty ? .failed : .succeeded
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

        // Discovery succeeded: trust it. A PID the ECU does not advertise is
        // dropped, even if that leaves the dashboard empty — showing tiles that
        // can never populate is worse than an honest empty state.
        signals = chosen.filter { signal in
            guard let pid = signal.pidValue else { return false }
            return supportedPIDs.contains(pid)
        }
    }

    /// Wraps a command so a request that never returns is detectable.
    private func send(
        _ command: String,
        timeout: TimeInterval,
        using elm: ELMClient
    ) async -> ELMResponse? {
        try? await elm.send(command, timeout: timeout)
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
        stallWatchdog?.cancel()
        stallWatchdog = nil
        pollTask?.cancel()
        pollTask = nil
        transport.shutdown()
        elm = nil
        lastLoopTick = nil
        readings.clear()
        dpf = nil
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
        if let last = lastUpdate {
            details["quietSeconds"] = String(Int(now.timeIntervalSince(last).rounded()))
        }
        session.event(.appLifecycle, details)
    }

    // MARK: - Silence

    /// True while the car — not the adapter — has stopped answering.
    func isVehicleSilent(now: Date = Date()) -> Bool {
        guard isConnected else { return false }
        return silence.isNoticeable(now: now, reference: lastUpdate ?? connectedAt)
    }

    /// One line for the header, or nil while the car is answering.
    ///
    /// The values on screen are the last ones the car gave us. Saying so is the
    /// difference between "the app is broken" and "the car is off".
    func silenceNotice(now: Date = Date()) -> String? {
        guard isVehicleSilent(now: now) else { return nil }
        var parts = ["Vehicle not responding"]
        if let last = lastUpdate {
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

    private func startPolling() {
        lastLoopTick = Date()
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.checkForStall()
            }
        }

        pollTask = Task { [weak self] in
            guard let self, let elm else { return }

            while !Task.isCancelled {
                // The car going quiet is judged on every iteration, from the
                // last sample and not from a success: measuring silence inside
                // the success path always read zero, so a sleeping ECU left no
                // data_gap in the log and looked like a frozen app.
                reportGapTransition(gapMonitor.update(now: Date(), lastSampleAt: lastUpdate))

                let reference = lastUpdate ?? connectedAt
                let quiet = silence.shouldPollQuietly(now: Date(), reference: reference)

                if quiet {
                    await quietCycle(using: elm)
                } else {
                    await sampleCycle(using: elm)
                }

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
                } else if let last = lastUpdate, Date().timeIntervalSince(last) > 5 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                if let connectedAt,
                   watchdog.shouldDisconnect(now: Date(), lastActivity: lastUpdate, connectedAt: connectedAt) {
                    disconnect(reason: .idleTimeout)
                    return
                }

                iteration += 1
            }
        }
    }

    /// One full pass: every live signal, then the periodic extra work.
    private func sampleCycle(using elm: ELMClient) async {
        // Manufacturer and DTC work address modules directly; restore
        // broadcast before sampling so live values keep their meaning.
        _ = try? await elm.send("ATSH7DF", timeout: 2)

        for signal in signals {
            if Task.isCancelled { return }
            await sample(signal, using: elm)
        }

        // A crank lasts one to two seconds. While the engine is off,
        // sample voltage a second time per cycle so the dip is caught.
        if (lastRPM ?? 0) < 400,
           let voltage = signals.first(where: { $0.pid == "42" }) {
            if Task.isCancelled { return }
            await sample(voltage, using: elm)
        }

        if isRecording,
           Date().timeIntervalSince(lastOdometerRead) > 60 {
            lastOdometerRead = Date()
            if let reading = await readOdometer(using: elm) {
                odometerKm = reading
            }
        }

        if Task.isCancelled { return }
        if identificationIsDue() {
            await attemptIdentification(using: elm)
        }
        if (lastRPM ?? 0) > 400, !verificationDone,
           [ProfileResolver.Method.calibration.rawValue,
            ProfileResolver.Method.vin.rawValue].contains(profileMatchMethod) {
            await verifyResolvedProfile(using: elm)
        }

        if Task.isCancelled { return }
        await stepDTCScan(using: elm)

        if Task.isCancelled { return }
        await stepPriorityScan(using: elm)
        if Task.isCancelled { return }
        await stepPriorityScan(using: elm)

        if Task.isCancelled { return }
        await stepProfileScan(using: elm)

        // One-time enrichment, once the bus is actually answering. Doing
        // this before polling was what delayed the first live reading.
        if !didInitialReads, isRecording, let last = lastUpdate,
           Date().timeIntervalSince(last) < 5 {
            didInitialReads = true
            await readDPF()
            await captureTripSnapshot(phase: "start", using: elm)
            if let connectStartedAt {
                session.event(.startupTiming, [
                    "phase": "first_sample",
                    "sinceConnectMs": Self.millis(
                        Date().timeIntervalSince(connectStartedAt) * 1000)
                ])
            }
        }
    }

    /// One gentle exchange while the car is asleep.
    ///
    /// The adapter's own supply voltage still works with the ignition off, so it
    /// is read for the display. Engine speed is then asked of the ECU: the reply
    /// to a real PID is what proves the car has woken, and a successful read
    /// returns the loop to the full cycle by itself. Without that probe, quiet
    /// mode would be a one-way door.
    private func quietCycle(using elm: ELMClient) async {
        // The sweep may have left a module header selected.
        _ = try? await elm.send("ATSH7DF", timeout: 2)

        if let reply = try? await elm.send("ATRV", timeout: 2) {
            supplyVolts = reply.supplyVolts
        }

        guard let rpm = signals.first(where: { $0.pid == "0C" }) else { return }
        await sample(rpm, using: elm)
    }

    private var iteration = 0

    /// One live signal. A failed read writes nothing: absence is meaningful.
    private func sample(_ signal: VehicleProfile.StandardSignal, using elm: ELMClient) async {
        guard let pid = signal.pidValue else { return }
        let command = String(format: "01%02X", pid)
        guard let reply = await send(command, timeout: 2, using: elm),
              let hex = reply.payloadHex,
              hex.hasPrefix(String(format: "41%02X", pid)),
              let data = LiveModel.bytes(String(hex.dropFirst(4))),
              let value = signal.decode(data)
        else { return }

        readings.setStandard(pid: signal.pid, value: value, at: Date())

        // The ECU may have been asleep when we probed. Now that it is answering,
        // ask again so an unnecessary empty capability set is not recorded.
        if discovery == .failed, !discoveryRetryDone {
            discoveryRetryDone = true
            await discoverCapabilities(using: elm)
            rebuildSignalList()
        }

        feedBatteryMonitor(pid: pid, value: value)

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
    }

    // MARK: - DTC scanning

    /// One scanner request per loop, with the target header selected immediately
    /// before it. The header must not be assumed to persist: live sampling
    /// resets addressing between steps.
    private func stepDTCScan(using elm: ELMClient) async {
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
            guard headerReply?.isOK == true else {
                active.ingestHeaderFailure()
                scanner = active
                return
            }
            let reply = try? await elm.send(request.command, timeout: 3)
            active.ingest(responseHex: reply?.payloadHex)
            scanner = active
        }
    }

    private func completeScan(_ diagnostics: VehicleDiagnostics, outcomes: [String: String]) {
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

    /// The live block: exhaust, catalyst and DPF temperatures plus differential
    /// pressure. Once per loop so a loaded drive actually characterises the
    /// sensor instead of sampling it every 90 seconds.
    private static let priorityLID: UInt8 = 0x10

    private func stepPriorityScan(using elm: ELMClient) async {
        guard let profile, profile.localIdentifiers.contains(Self.priorityLID) else { return }
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let reply = try? await elm.send("2110", timeout: 3)
        guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else { return }

        for decoded in profile.decode(frame) {
            readings.setManufacturer(decoded, at: Date())
            if decoded.itemNumber == 119 { trackRegeneration(dpfTemperature: decoded.value) }
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
    }

    /// One local identifier per loop, so 76 blocks refresh in the background
    /// without blocking live sampling.
    private func stepProfileScan(using elm: ELMClient) async {
        guard let profile, !profile.localIdentifiers.isEmpty else { return }
        let count = profile.localIdentifiers.count
        let lid = profile.localIdentifiers[profileIndex % count]
        profileIndex += 1

        // The cycle closes as the index wraps, which is after every identifier
        // has been requested once.
        if profileIndex % count == 0 {
            if let summary = sweep.completeCycle(planned: profile.localIdentifiers) {
                session.event(.sweepCompleted, [
                    "cycle": String(summary.cycle),
                    "attempted": String(summary.attempted),
                    "answered": String(summary.answered),
                    "missing": summary.missing.map { String(format: "%02X", $0) }.joined(separator: ",")
                ])
            }
        }

        // Recorded before the request: a timeout is still an attempt.
        sweep.recordAttempt(lid)

        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let command = String(format: "21%02X", lid)
        guard let reply = try? await elm.send(command, timeout: 3),
              let hex = reply.payloadHex,
              let frame = MUT21Frame(hex: hex)
        else { return }

        sweep.recordAnswer(lid)
        let decodedValues = profile.decode(frame)

        for decoded in decodedValues {
            readings.setManufacturer(decoded, at: Date())
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
    }

    /// Everything a future comparison needs, captured once at each end of a
    /// session so regen interval and soot-per-km become measurable rather than
    /// inferred.
    private func captureTripSnapshot(phase: String, using elm: ELMClient) async {
        guard let profile else { return }
        var details: [String: String] = ["phase": phase]

        for lid in [UInt8(0x03), 0x10, 0x11, 0x12] {
            _ = try? await elm.send("ATSH7E0", timeout: 2)
            guard let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3),
                  let hex = reply.payloadHex,
                  let frame = MUT21Frame(hex: hex)
            else { continue }
            for value in profile.decode(frame) {
                let key = value.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: ".", with: "")
                details[String(format: "%02X.%@", lid, key)] = String(format: "%.2f", value.value)
            }
        }
        _ = try? await elm.send("ATSH7DF", timeout: 2)

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

    /// Odometer from the engine ECU (item 145). Needed because regeneration
    /// interval and soot-per-km are otherwise not computable.
    private func readOdometer(using elm: ELMClient) async -> Int? {
        guard let profile else { return nil }
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let reply = try? await elm.send("2103", timeout: 2)
        _ = try? await elm.send("ATSH7DF", timeout: 2)
        guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else { return nil }
        return profile.decode(frame)
            .first { $0.itemNumber == 145 }
            .map { Int($0.value) }
    }

    /// Intake air temperature with the engine off, as an ambient proxy: this ECU
    /// has no ambient-temperature PID.
    private func readAmbient(using elm: ELMClient) async -> Double? {
        guard let reply = try? await elm.send("010F", timeout: 2),
              let hex = reply.payloadHex, hex.hasPrefix("410F"),
              let bytes = LiveModel.bytes(String(hex.dropFirst(4))),
              let first = bytes.first
        else { return nil }
        return Double(first) - 40
    }

    /// Regeneration is detected from the filter temperature rather than the ECU's
    /// flag: the temperature lives in the live block at several Hz, while the flag
    /// block refreshes once a minute and a half.
    private func trackRegeneration(dpfTemperature: Double) {
        switch regenDetector.ingest(tempC: dpfTemperature, at: Date()) {
        case .started(let temp):
            regenSootAtStart = manufacturer.values.first { $0.itemNumber == 155 }?.value
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
            if let after = manufacturer.values.first(where: { $0.itemNumber == 155 })?.value {
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

    private func readDPF() async {
        guard let elm else { return }
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        var frames: [UInt8: MUT21Frame] = [:]
        for lid in [UInt8(0x11), 0x12] {
            let command = String(format: "21%02X", lid)
            guard let reply = try? await elm.send(command, timeout: 6),
                  let hex = reply.payloadHex,
                  let frame = MUT21Frame(hex: hex)
            else { continue }
            frames[lid] = frame
        }
        _ = try? await elm.send("ATSH7DF", timeout: 2)
        let status = MUT21.status(from: frames)
        if status.sootByAccumulation != nil || status.regenerationCount != nil {
            dpf = status
        }
    }

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
