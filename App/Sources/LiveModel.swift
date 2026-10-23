import Foundation
import Observation
import OBDLink
import OBDCore

/// What the shell polls. Deliberately a small fixed set for now: profile-driven
/// tile generation is the next step, once the recorder exists.
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
            guard data.count >= 2 else { return nil }
            return (Double(data[0]) * 256 + Double(data[1])) * 10 / 10
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

    var phase: Phase = .idle
    var status = "Not connected"
    var adapterName = ""
    var values: [LiveSignal: Double] = [:]
    var dpf: DPFStatus?
    var lastUpdate: Date?

    private let transport = BLETransport()
    private var elm: ELMClient?
    private var pollTask: Task<Void, Never>?

    var isConnected: Bool { phase == .connected }

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
        transport.shutdown()
        elm = nil
        phase = .idle
        status = "Not connected"
        values = [:]
        dpf = nil
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            guard let self, let elm else { return }
            while !Task.isCancelled {
                for signal in LiveSignal.allCases {
                    if Task.isCancelled { return }
                    let command = String(format: "01%02X", signal.rawValue)
                    guard let reply = try? await elm.send(command, timeout: 2),
                          let hex = reply.payloadHex,
                          hex.hasPrefix(String(format: "41%02X", signal.rawValue)),
                          let data = LiveModel.bytes(String(hex.dropFirst(4))),
                          let value = signal.decode(data)
                    else { continue }
                    values[signal] = value
                    lastUpdate = Date()
                }
            }
        }
    }

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
