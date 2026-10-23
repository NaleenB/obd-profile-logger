import Foundation
import Observation
import OBDLink
import OBDCore

/// What the shell polls. Deliberately a small fixed set for now: profile-driven
/// tile generation is a separate milestone.
enum LiveSignal: UInt8, CaseIterable {
    case rpm = 0x0C
    case speed = 0x0D
    case coolant = 0x05
    case map = 0x0B
    case maf = 0x10
    case load = 0x04
    case rail = 0x23
    case voltage = 0x42

    var title: String {
        switch self {
        case .rpm: return "RPM"
        case .speed: return "Speed"
        case .coolant: return "Coolant"
        case .map: return "MAP"
        case .maf: return "Air flow"
        case .load: return "Load"
        case .rail: return "Rail"
        case .voltage: return "Voltage"
        }
    }

    var unit: String {
        switch self {
        case .rpm: return "rpm"
        case .speed: return "km/h"
        case .coolant: return "°C"
        case .map: return "kPa"
        case .maf: return "g/s"
        case .load: return "%"
        case .rail: return "bar"
        case .voltage: return "V"
        }
    }

    var fractionDigits: Int {
        switch self {
        case .rpm: return 0
        case .voltage: return 2
        case .maf: return 2
        case .rail: return 1
        default: return 0
        }
    }

    /// Decodes the data bytes (mode/PID echo already removed).
    func decode(_ data: [UInt8]) -> Double? {
        switch self {
        case .rpm:
            guard data.count >= 2 else { return nil }
            return (Double(data[0]) * 256 + Double(data[1])) / 4
        case .speed, .coolant, .map, .load:
            guard let a = data.first else { return nil }
            switch self {
            case .coolant: return Double(a) - 40
            case .load: return Double(a) * 100 / 255
            default: return Double(a)
            }
        case .maf:
            guard data.count >= 2 else { return nil }
            return (Double(data[0]) * 256 + Double(data[1])) / 100
        case .rail:
            // PID 0x23 is 10 kPa per bit; the UI shows bar, so divide by 10.
            guard data.count >= 2 else { return nil }
            return PIDScaling.railPressureBar(a: data[0], b: data[1])
        case .voltage:
            guard data.count >= 2 else { return nil }
            return (Double(data[0]) * 256 + Double(data[1])) / 1000
        }
    }
}

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
    var values: [LiveSignal: Double] = [:]
    var dpf: DPFStatus?
    var lastUpdate: Date?

    var recording: RecordingState = .idle
    var lastSessionURL: URL?
    var exportURL: URL?
    var notice: String?

    private let transport = BLETransport()
    private var elm: ELMClient?
    private var pollTask: Task<Void, Never>?

    private var recorder: SessionRecorder?
    private var scanner: DTCScanner?
    private var lastScanSignature: String?
    private var iteration = 0
    private var lastDTCStep = Date.distantPast

    /// Roughly 10 s between DTC scans at the current poll cadence.
    private let dtcScanInterval: TimeInterval = 10
    private let profileID = "mitsubishi-outlander-2016-4n14"

    var isConnected: Bool { phase == .connected }
    var isRecording: Bool { recording.isRecording }

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
                _ = try? await client.send("ATSP6", timeout: 2)

                phase = .connected
                status = "Connected"

                await readDPF()
                record(.adapterConnected, ["adapter": adapterName])
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
            try? recorder?.recordEvent(.adapterDisconnected, details: ["reason": "user"])
            try? recorder?.recordEvent(.recordingInterrupted, details: ["reason": "adapter disconnected"])
            stopRecording(reason: "adapter_disconnected")
        } else {
            record(.adapterDisconnected, ["reason": "user"])
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
        guard recorder == nil else { return }

        let manifest = SessionManifest(
            sessionID: SessionStore.makeSessionID(),
            startedAt: WallClock.iso(),
            appVersion: Self.appVersion,
            vehicleProfileID: profileID,
            adapterName: adapterName.isEmpty ? nil : adapterName,
            adapterIdentifier: transport.adapterIdentifier.isEmpty ? nil : transport.adapterIdentifier,
            supportedPIDs: nil,
            notes: [
                "Polled signals are a fixed core subset, not a full capability map.",
                "DTC scans cover the engine (7E0) and transmission (7E1) only."
            ]
        )

        do {
            let created = try SessionStore.createSession(manifest: manifest)
            try created.recordEvent(.sessionStarted, details: [
                "profile": profileID,
                "polledPIDs": LiveSignal.allCases
                    .map { String(format: "%02X", $0.rawValue) }
                    .joined(separator: ",")
            ])
            recorder = created
            lastSessionURL = created.directory
            exportURL.map(SessionArchive.discard)
            exportURL = nil
            recording = .recording(sessionID: created.sessionID)
            notice = nil
        } catch {
            recording = .failed("\(error)")
            notice = "\(error)"
        }
    }

    func stopRecording(reason: String) {
        guard let active = recorder else {
            recording = .idle
            return
        }
        active.finish(reason: reason)
        recorder = nil
        lastSessionURL = active.directory
        recording = .stopped(sessionID: active.sessionID)

        let samples = SessionStore.lineCount(at: active.directory,
                                             filename: SessionRecorder.samplesFilename())
        if samples == 0 {
            notice = "Session saved with no samples. Nothing was read while recording."
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

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            guard let self, let elm else { return }

            while !Task.isCancelled {
                // DTC scans address 7E0/7E1 directly; restore broadcast before
                // sampling so live values keep their usual meaning.
                _ = try? await elm.send("ATSH7DF", timeout: 2)

                for signal in LiveSignal.allCases {
                    if Task.isCancelled { return }
                    await sample(signal, using: elm)
                }

                if Task.isCancelled { return }
                await stepDTCScan(using: elm)

                iteration += 1
            }
        }
    }

    /// One live signal. A failed read writes nothing: absence is meaningful.
    private func sample(_ signal: LiveSignal, using elm: ELMClient) async {
        let command = String(format: "01%02X", signal.rawValue)
        guard let reply = try? await elm.send(command, timeout: 2),
              let hex = reply.payloadHex,
              hex.hasPrefix(String(format: "41%02X", signal.rawValue)),
              let data = LiveModel.bytes(String(hex.dropFirst(4))),
              let value = signal.decode(data)
        else { return }

        values[signal] = value
        lastUpdate = Date()

        try? recorder?.recordSample(
            pid: signal.rawValue,
            name: signal.title,
            value: value,
            unit: signal.unit,
            raw: hex
        )
    }

    // MARK: - DTC scanning

    /// One scanner command per loop, interleaved with live reads, so DTC work
    /// never stalls sampling.
    private func stepDTCScan(using elm: ELMClient) async {
        if scanner == nil {
            guard Date().timeIntervalSince(lastDTCStep) >= dtcScanInterval else { return }
            scanner = DTCScanner()
            lastDTCStep = Date()
        }
        guard var active = scanner else { return }

        switch active.next() {
        case .finished:
            scanner = nil
            _ = try? await elm.send("ATSH7DF", timeout: 2)
            _ = try? await elm.send("ATAR", timeout: 2)
            completeScan(active.diagnostics, outcomes: active.outcomeDetails)
        case .command(let command):
            let reply = try? await elm.send(command, timeout: 3)
            active.ingest(responseHex: reply?.payloadHex)
            scanner = active
        }
    }

    private func completeScan(_ diagnostics: VehicleDiagnostics, outcomes: [String: String]) {
        let signature = diagnostics.modules
            .map { "\($0.module):\($0.allCodes.joined(separator: ",")):\($0.isComplete)" }
            .joined(separator: "|")

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

        record(.dtcSnapshot, details)
    }

    // MARK: - DPF

    private func readDPF() async {
        guard let elm else { return }
        _ = try? await elm.send("ATSH7E0", timeout: 2)
        var frames: [UInt8: MUT21Frame] = [:]
        for lid in [UInt8(0x11), 0x12] {
            let command = String(format: "21%02X", lid)
            guard let reply = try? await elm.send(command, timeout: 3),
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

    private func record(_ type: SessionEventType, _ details: [String: String] = [:]) {
        guard let recorder, !recorder.isClosed else { return }
        do {
            try recorder.recordEvent(type, details: details)
        } catch {
            notice = "Recording error: \(error)"
            recording = .failed("\(error)")
        }
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
