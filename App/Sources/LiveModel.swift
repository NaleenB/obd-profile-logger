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
    private var identityRetried = false
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
    private var inFlightSince: Date?
    private var regenDetector = RegenDetector()
    private var regenSootAtStart: Double?
    private var stallWatchdog: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectedAt: Date?

    private var scanner: DTCScanner?
    private var snapshotGate = DTCSnapshotGate()
    private var profileIndex = 0
    private var sweepAttempted: Set<UInt8> = []
    private var sweepAnswered: Set<UInt8> = []
    private var sweepCycles = 0
    private var lastDTCStep = Date.distantPast

    /// Roughly 10 s between DTC scans at the current poll cadence.
    private let dtcScanInterval: TimeInterval = 10
    /// "auto" or an explicit profile id. Persisted so the choice survives a
    /// relaunch. Automatic is the default: most drivers should never need this.
    private(set) var profileSelection: String =
        UserDefaults.standard.string(forKey: "profileSelection") ?? "auto"

    /// Identifier actually in use after resolution. Goes into the manifest.
    private(set) var profileID: String = ProfileCatalog.defaultID

    /// Profiles bundled with the app, for the picker.
    let availableProfiles = ProfileCatalog.entries()

    /// True when the car answered a manufacturer service at connect time.
    private(set) var manufacturerServiceAvailable = false

    init() {
        // Before connecting there is nothing to detect, so show the explicit
        // choice if there is one, otherwise the default.
        let initial = profileSelection == "auto" ? ProfileCatalog.defaultID : profileSelection
        loadProfile(id: initial)
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

    private func resolveProfile(
        manufacturerAvailable: Bool,
        identity: VehicleIdentity,
        using elm: ELMClient
    ) async {
        guard profileSelection == "auto" else {
            loadProfile(id: profileSelection)
            profileMatchMethod = "manual"
            return
        }
        let all = availableProfiles.compactMap {
            try? ProfileCatalog.load(id: resourceName(for: $0.id))
        }
        // With no identity, ask the car a question only the right offsets can
        // answer: decode "engine speed" from the manufacturer block and see
        // whether it agrees with the ECU's own rpm.
        if manufacturerAvailable, !identityResolved {
            if let matched = await identifyByAgreement(among: all, using: elm) {
                loadProfile(id: matched.id)
                profileMatchMethod = "agreement"
                notice = "Identified \(matched.model) by matching manufacturer data against live readings."
                return
            }
        }

        var chosen = ProfileCatalog.automaticID(
            manufacturerAvailable: manufacturerAvailable,
            identity: identity,
            among: all
        )

        // Calibration and VIN can be unreadable on the first attempt, especially
        // with the ignition still off. Unknown identity is not the same as a
        // mismatch: if there is exactly one specific profile, use it and say so.
        let unknownIdentity = !identityResolved
        let specific = all.filter { $0.manufacturer != "Generic" }
        if manufacturerAvailable, unknownIdentity, chosen == "generic-iso15765-can", specific.count == 1 {
            chosen = specific[0].id
            profileMatchMethod = "assumed"
            notice = "Calibration could not be read, so \(specific[0].model) is assumed. Change it in the profile menu if that is wrong."
        } else if manufacturerAvailable, chosen == "generic-iso15765-can" {
            profileMatchMethod = "generic"
            notice = "This car answers a manufacturer service, but no profile matches its calibration. Using generic OBD only."
        } else if chosen != "generic-iso15765-can" {
            profileMatchMethod = identity.calibrationID != nil ? "calibration" : "vin"
        }

        loadProfile(id: chosen ?? ProfileCatalog.defaultID)
    }

    /// How the active profile was chosen: calibration, vin, agreement, assumed,
    /// or manual. Recorded in the manifest so a wrong decode can be traced.
    private(set) var profileMatchMethod: String = "default"

    private func identifyByAgreement(among profiles: [VehicleProfile], using elm: ELMClient) async -> VehicleProfile? {
        let specifics = profiles.filter { $0.manufacturer != "Generic" }
        guard !specifics.isEmpty else { return nil }

        // Standard values the car reports independently.
        var standardRPM: Double?
        if let reply = try? await elm.send("010C", timeout: 3),
           let hex = reply.payloadHex, hex.hasPrefix("410C"),
           let bytes = LiveModel.bytes(String(hex.dropFirst(4))), bytes.count >= 2 {
            standardRPM = (Double(bytes[0]) * 256 + Double(bytes[1])) / 4
        }
        var standardCoolant: Double?
        if let reply = try? await elm.send("0105", timeout: 3),
           let hex = reply.payloadHex, hex.hasPrefix("4105"),
           let bytes = LiveModel.bytes(String(hex.dropFirst(4))), let first = bytes.first {
            standardCoolant = Double(first) - 40
        }
        // Needs the engine turning, or every profile agrees on zero.
        guard let standardRPM, standardRPM > 400 else { return nil }

        var frames: [UInt8: MUT21Frame] = [:]
        for lid in [UInt8(0x01), 0x02, 0x03] {
            _ = try? await elm.send("ATSH7E0", timeout: 2)
            let reply = try? await elm.send(String(format: "21%02X", lid), timeout: 3)
            if let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) { frames[lid] = frame }
        }
        _ = try? await elm.send("ATSH7DF", timeout: 2)

        var best: (profile: VehicleProfile, evidence: ProfileEvidence)?
        for profile in specifics {
            var manufacturerRPM: Double?
            var manufacturerCoolant: Double?
            var odometer: Double?
            for frame in frames.values {
                for value in profile.decode(frame) {
                    switch value.itemNumber {
                    case 2: manufacturerRPM = value.value
                    case 7: manufacturerCoolant = value.value
                    case 145: odometer = value.value
                    default: break
                    }
                }
            }
            let evidence = ProfileEvidence(
                manufacturerRPM: manufacturerRPM,
                standardRPM: standardRPM,
                manufacturerCoolant: manufacturerCoolant,
                standardCoolant: standardCoolant,
                odometerKm: odometer
            )
            guard ProfileMatcher.isConvincing(evidence) else { continue }
            if best == nil || ProfileMatcher.score(evidence) > ProfileMatcher.score(best!.evidence) {
                best = (profile, evidence)
            }
        }
        return best?.profile
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
    private func detectManufacturerService(using elm: ELMClient) async -> Bool {
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let reply = try? await elm.send("2111", timeout: 3)
        _ = try? await elm.send("ATSH7DF", timeout: 2)
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

    /// "auto" or a profile id. Takes effect on the next connection: the
    /// protocol, signal list and module headers are fixed at connect time.
    func selectProfile(_ id: String) {
        guard id != profileSelection else { return }
        profileSelection = id
        UserDefaults.standard.set(id, forKey: "profileSelection")
        if id != "auto" { loadProfile(id: id) }
        if isConnected {
            // Service 0x21 blocks can be decoded immediately with different
            // offsets; only the protocol and signal list need a reconnect.
            readings.clearManufacturer()
            rebuildSignalList()
            notice = "Profile applied. Reconnect to change protocol or signal list."
        }
    }

    var profileTitle: String {
        if profileSelection == "auto" {
            let resolved = availableProfiles.first { $0.id == profileID }?.title ?? "Profile"
            return isConnected ? "Auto · \(resolved)" : "Auto"
        }
        return availableProfiles.first { $0.id == profileID }?.title ?? "Profile"
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
            do {
                try await transport.start()
                let candidate = try await transport.findAdapter(scanSeconds: 8, nameFilter: nil)
                status = "Connecting to \(candidate.name.isEmpty ? "adapter" : candidate.name)…"

                let port = try await transport.connect(candidate)
                _ = port
                KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)

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

                manufacturerServiceAvailable = await detectManufacturerService(using: client)
                identity = await readIdentity(using: client)
                identityResolved = identity.calibrationID != nil || identity.vin != nil
                await resolveProfile(manufacturerAvailable: manufacturerServiceAvailable,
                                     identity: identity, using: client)

                await discoverCapabilities(using: client)
                rebuildSignalList()

                lastVolts = nil
                lastRPM = nil
                batteryLogged = false
                batteryReport = nil
                runningSince = nil
                discoveryRetryDone = false
                gapMonitor = DataGapMonitor(threshold: 10)

                connectedAt = Date()
                phase = .connected
                status = signals.isEmpty ? "Connected — no supported PIDs found" : "Connected"

                if let protocolName = try? await client.send("ATDP", timeout: 2) {
                    protocolDescription = protocolName.statusSummary
                }
                _ = protocolAccepted

                // Read DPF once for immediate display. Recording is usually not
                // active yet; the profile sweep records these same LIDs when it is.
                await readDPF()
                odometerKm = await readOdometer(using: client)
                ambientTempC = await readAmbient(using: client)

                // Recording is automatic: connecting is the intent to record.
                // Start it first so the connection event is not discarded.
                startRecording()
                session.event(.adapterConnected, ["adapter": adapterName])
                await captureTripSnapshot(phase: "start", using: client)
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
        inFlightSince = nil
        readings.clear()
        dpf = nil
        lastRPM = nil
        lastVolts = nil
        batteryLogged = false
        runningSince = nil

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
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

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
            guard let reply = try? await elm.send(command, timeout: 6),
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
        inFlightSince = Date()
        defer { inFlightSince = nil }
        return try? await elm.send(command, timeout: timeout)
    }

    /// A command outstanding for far longer than its own timeout means the link
    /// is wedged — usually after the phone was suspended mid-request.
    func checkForStall(now: Date = Date()) {
        guard phase == .connected, let started = inFlightSince else { return }
        guard now.timeIntervalSince(started) > 20 else { return }
        recoverFromStall()
    }

    private func recoverFromStall() {
        notice = "Connection stalled and was reset. Tap Connect to resume."
        status = "Connection stalled"
        if isRecording { stopRecording(reason: "stalled") }
        stallWatchdog?.cancel()
        stallWatchdog = nil
        pollTask?.cancel()
        pollTask = nil
        transport.shutdown()
        elm = nil
        inFlightSince = nil
        readings.clear()
        dpf = nil
        phase = .failed("Connection stalled")
    }

    /// Called when the app returns to the foreground: iOS may have suspended a
    /// request mid-flight, leaving the loop waiting forever.
    func appDidBecomeActive() {
        checkForStall()
    }

    // MARK: - Polling

    private func startPolling() {
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
                await stepDTCScan(using: elm)

                if Task.isCancelled { return }
                await stepPriorityScan(using: elm)
                if Task.isCancelled { return }
                await stepPriorityScan(using: elm)

                if Task.isCancelled { return }
                await stepProfileScan(using: elm)

                if case .failed = recording {
                    // A write failure has stopped the session; keep sampling for
                    // the UI but stop pretending we are recording.
                    syncRecordingState()
                }

                // A sleeping vehicle will not start answering because we ask
                // faster. Back off so a parked session is cheap.
                if let last = lastUpdate, Date().timeIntervalSince(last) > 5 {
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
        reportGapTransition(gapMonitor.update(now: Date(), lastSampleAt: lastUpdate))

        // The ECU may have been asleep when we probed. Now that it is answering,
        // ask again so an unnecessary empty capability set is not recorded.
        if discovery == .failed, !discoveryRetryDone {
            discoveryRetryDone = true
            await discoverCapabilities(using: elm)
            rebuildSignalList()
        }

        if !identityResolved, !identityRetried {
            identityRetried = true
            identity = await readIdentity(using: elm)
            identityResolved = identity.calibrationID != nil || identity.vin != nil
            if identityResolved {
                await resolveProfile(manufacturerAvailable: manufacturerServiceAvailable,
                                     identity: identity, using: elm)
                rebuildSignalList()
            }
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

        if profileIndex % count == 0, !sweepAttempted.isEmpty {
            sweepCycles += 1
            session.event(.sweepCompleted, [
                "cycle": String(sweepCycles),
                "attempted": String(sweepAttempted.count),
                "answered": String(sweepAnswered.count),
                "missing": profile.localIdentifiers
                    .filter { !sweepAttempted.contains($0) }
                    .map { String(format: "%02X", $0) }
                    .joined(separator: ",")
            ])
            sweepAttempted.removeAll()
        }

        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let command = String(format: "21%02X", lid)
        guard let reply = try? await elm.send(command, timeout: 6),
              let hex = reply.payloadHex,
              let frame = MUT21Frame(hex: hex)
        else { return }

        sweepAttempted.insert(lid)
        let decodedValues = profile.decode(frame)
        if !decodedValues.isEmpty { sweepAnswered.insert(lid) }

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
        let reply = try? await elm.send("2103", timeout: 3)
        _ = try? await elm.send("ATSH7DF", timeout: 2)
        guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else { return nil }
        return profile.decode(frame)
            .first { $0.itemNumber == 145 }
            .map { Int($0.value) }
    }

    /// Intake air temperature with the engine off, as an ambient proxy: this ECU
    /// has no ambient-temperature PID.
    private func readAmbient(using elm: ELMClient) async -> Double? {
        guard let reply = try? await elm.send("010F", timeout: 3),
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
