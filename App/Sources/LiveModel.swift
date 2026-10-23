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
    /// Latest value per PID, keyed by two-digit hex.
    var values: [String: Double] = [:]
    var dpf: DPFStatus?
    var lastUpdate: Date?

    /// Manufacturer parameters decoded through the vehicle profile.
    private(set) var manufacturer: [String: DecodedParameter] = [:]
    private(set) var profile: VehicleProfile?

    var recording: RecordingState = .idle
    var lastSessionURL: URL?
    var exportURL: URL?
    var notice: String?

    private let transport = BLETransport()
    private let session = RecordingSession()
    private var elm: ELMClient?
    private var pollTask: Task<Void, Never>?

    private var scanner: DTCScanner?
    private var lastScanSignature: String?
    private var profileIndex = 0
    private var lastDTCStep = Date.distantPast

    /// Roughly 10 s between DTC scans at the current poll cadence.
    private let dtcScanInterval: TimeInterval = 10
    private let profileID = "mitsubishi-outlander-2016-4n14"

    init() {
        do {
            profile = try VehicleProfileLoader.load(named: "outlander-2016-4n14")
        } catch {
            notice = "Vehicle profile unavailable: \(error)"
        }
    }

    var isConnected: Bool { phase == .connected }
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

    /// PIDs the ECU advertised. Empty means discovery has not run or failed, in
    /// which case nothing is filtered out.
    private(set) var supportedPIDs: Set<UInt8> = []

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

                await discoverCapabilities(using: client)
                rebuildSignalList()

                phase = .connected
                status = signals.isEmpty ? "Connected — no supported PIDs found" : "Connected"

                if let protocolName = try? await client.send("ATDP", timeout: 2) {
                    protocolDescription = protocolName.statusSummary
                }
                _ = protocolAccepted

                // Read DPF once for immediate display. Recording is usually not
                // active yet; the profile sweep records these same LIDs when it is.
                await readDPF()
                session.event(.adapterConnected, ["adapter": adapterName])
                startPolling()
            } catch {
                phase = .failed("\(error)")
                status = "\(error)"
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil

        if isRecording {
            session.event(.adapterDisconnected, ["reason": "user"])
            session.event(.recordingInterrupted, ["reason": "adapter disconnected"])
            stopRecording(reason: "adapter_disconnected")
        } else {
            session.event(.adapterDisconnected, ["reason": "user"])
        }

        transport.shutdown()
        elm = nil
        phase = .idle
        status = "Not connected"
        values = [:]
        dpf = nil
        scanner = nil
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            stopRecording(reason: "user")
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }

        let manifest = SessionManifest(
            sessionID: SessionStore.makeSessionID(),
            startedAt: WallClock.iso(),
            appVersion: Self.appVersion,
            vehicleProfileID: profileID,
            adapterName: adapterName.isEmpty ? nil : adapterName,
            adapterIdentifier: transport.adapterIdentifier.isEmpty ? nil : transport.adapterIdentifier,
            supportedPIDs: nil,
            notes: [
                "Standard PIDs plus service 0x21 manufacturer observations.",
                "DTC scans cover the engine (7E0) and transmission (7E1) only."
            ]
        )

        do {
            try session.start(
                manifest: manifest,
                details: ["polledPIDs": signals.map(\.pid).joined(separator: ",")]
            )
            syncRecordingState()
            lastSessionURL = session.directory
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = nil
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
        let result = session.stop(reason: reason)
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

    func exportLastSession() {
        guard let directory = lastSessionURL else {
            notice = "No session to export yet."
            return
        }
        do {
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = try SessionArchive.export(directory)
        } catch {
            notice = "\(error)"
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
    }

    /// Profile signals if it has any, otherwise the generic baseline — then
    /// filtered by what the car actually reports.
    private func rebuildSignalList() {
        let base = profile?.signals ?? []
        let chosen = base.isEmpty ? GenericSignals.defaults : base

        if supportedPIDs.isEmpty {
            signals = chosen
            return
        }

        let filtered = chosen.filter { signal in
            guard let pid = signal.pidValue else { return false }
            return supportedPIDs.contains(pid)
        }

        // Never end up with an empty dashboard just because discovery was odd:
        // if the filter removes everything, keep the unfiltered set.
        signals = filtered.isEmpty ? chosen : filtered
    }

    // MARK: - Polling

    private func startPolling() {
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

                if Task.isCancelled { return }
                await stepDTCScan(using: elm)

                if Task.isCancelled { return }
                await stepProfileScan(using: elm)

                if case .failed = recording {
                    // A write failure has stopped the session; keep sampling for
                    // the UI but stop pretending we are recording.
                    syncRecordingState()
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
        guard let reply = try? await elm.send(command, timeout: 2),
              let hex = reply.payloadHex,
              hex.hasPrefix(String(format: "41%02X", pid)),
              let data = LiveModel.bytes(String(hex.dropFirst(4))),
              let value = signal.decode(data)
        else { return }

        values[signal.pid] = value
        lastUpdate = Date()

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
        guard signature != lastScanSignature else { return }
        lastScanSignature = signature

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

    /// One local identifier per loop, so 76 blocks refresh in the background
    /// without blocking live sampling.
    private func stepProfileScan(using elm: ELMClient) async {
        guard let profile, !profile.localIdentifiers.isEmpty else { return }
        let lid = profile.localIdentifiers[profileIndex % profile.localIdentifiers.count]
        profileIndex += 1

        _ = try? await elm.send("ATSH7E0", timeout: 2)
        let command = String(format: "21%02X", lid)
        guard let reply = try? await elm.send(command, timeout: 6),
              let hex = reply.payloadHex,
              let frame = MUT21Frame(hex: hex)
        else { return }

        for decoded in profile.decode(frame) {
            manufacturer[decoded.id] = decoded
            if isRecording {
                let written = session.manufacturerSample(
                    lid: decoded.lid,
                    itemNumber: decoded.itemNumber,
                    name: decoded.name,
                    value: decoded.value,
                    unit: decoded.unit ?? "",
                    raw: hex
                )
                if !written { syncRecordingState() }
            }
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
