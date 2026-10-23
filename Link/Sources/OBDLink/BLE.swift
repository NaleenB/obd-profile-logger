import Foundation
import CoreBluetooth

public enum BLEError: Error, CustomStringConvertible {
    case unavailable(String)
    case noDevice(String)
    case notConnected
    case noSerialPort
    case timeout(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .unavailable(let s): return "Bluetooth unavailable: \(s)"
        case .noDevice(let s): return "No matching adapter found. \(s)"
        case .notConnected: return "Adapter is not connected"
        case .noSerialPort: return "Adapter exposes no usable serial characteristic"
        case .timeout(let c): return "Timed out waiting for a response to '\(c)'"
        case .writeFailed(let s): return "Write failed: \(s)"
        }
    }
}

public struct SerialPort {
    public let label: String
    public let write: CBCharacteristic
    public let notify: CBCharacteristic
    /// Chosen from the characteristic's advertised properties, not assumed:
    /// some modules expose write-without-response only.
    public let writeType: CBCharacteristicWriteType
}

/// Talks to a BLE OBD-II dongle.
///
/// Deliberately dumb about ELM327 semantics: it moves bytes and reassembles
/// responses until the `>` prompt. ELM-level parsing lives in ELMClient.
public final class BLETransport: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    static let fff0 = CBUUID(string: "FFF0")
    static let fff1 = CBUUID(string: "FFF1")
    static let fff2 = CBUUID(string: "FFF2")
    static let microchipService = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    static let microchipNotify = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318")
    static let microchipWrite = CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE")
    static let deviceInfoService = CBUUID(string: "180A")

    public struct Candidate {
        public let peripheral: CBPeripheral
        public let name: String
        public let score: Int
        public let rssi: Int
        public let detail: String
    }

    private var central: CBCentralManager?
    private let lock = NSLock()

    private var peripheral: CBPeripheral?
    private var port: SerialPort?
    private var rxBuffer = Data()

    private var pending: CheckedContinuation<String, Error>?
    private var pendingCommand = ""
    private var timeoutItem: DispatchWorkItem?

    private var powerCont: CheckedContinuation<Void, Error>?
    private var scanCont: CheckedContinuation<[Candidate], Error>?
    private var readyCont: CheckedContinuation<SerialPort, Error>?

    private var candidates: [Candidate] = []
    private var servicesRemaining = 0
    private var mergedServices: [UUID: Set<CBUUID>] = [:]
    public private(set) var lastScanDetails: [[String: Any]] = []

    /// Called when the link drops. The caller decides whether that was expected.
    public var onDisconnect: ((String) -> Void)?

    /// Called for non-fatal problems the caller may want to surface.
    public var onWarning: ((String) -> Void)?

    public private(set) var adapterName = ""
    public private(set) var adapterIdentifier = ""
    public private(set) var deviceInfo: [String: String] = [:]
    public private(set) var discoveredNames: [String] = []

    // MARK: - Lifecycle

    public func start() async throws {
        let central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        self.central = central

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if central.state == .poweredOn {
                lock.unlock()
                cont.resume()
                return
            }
            powerCont = cont
            lock.unlock()
        }
    }

    public func shutdown() {
        central?.stopScan()
        if let peripheral, peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        lock.lock()
        let cont = powerCont
        powerCont = nil
        lock.unlock()

        switch central.state {
        case .poweredOn:
            cont?.resume()
        case .unauthorized:
            cont?.resume(throwing: BLEError.unavailable(
                "permission denied. Grant Bluetooth access in System Settings > Privacy & Security > Bluetooth, then rerun."))
        case .poweredOff:
            cont?.resume(throwing: BLEError.unavailable("Bluetooth is turned off"))
        case .unsupported:
            cont?.resume(throwing: BLEError.unavailable("this Mac does not support Bluetooth Low Energy"))
        case .resetting, .unknown:
            cont?.resume(throwing: BLEError.unavailable("Bluetooth is still initialising, try again"))
        @unknown default:
            cont?.resume(throwing: BLEError.unavailable("unknown Bluetooth state"))
        }
    }

    // MARK: - Discovery

    public func scan(seconds: TimeInterval) async throws -> [Candidate] {
        guard let central else { throw BLEError.unavailable("not started") }

        candidates = []
        discoveredNames = []
        mergedServices = [:]

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Candidate], Error>) in
            lock.lock()
            scanCont = cont
            lock.unlock()

            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finishScan()
            }
        }
    }

    private func finishScan() {
        central?.stopScan()

        lock.lock()
        let cont = scanCont
        scanCont = nil
        let list = candidates
        lastScanDetails = list
            .sorted { $0.rssi > $1.rssi }
            .map {
                [
                    "name": $0.name.isEmpty ? "(unnamed)" : $0.name,
                    "identifier": $0.peripheral.identifier.uuidString,
                    "rssi": $0.rssi,
                    "score": $0.score
                ]
            }
        lock.unlock()

        cont?.resume(returning: list)
    }

    public func findAdapter(scanSeconds: TimeInterval, nameFilter: String?) async throws -> Candidate {
        let list = try await scan(seconds: scanSeconds)

        // A previously working adapter is the strongest possible signal: these
        // dongles often advertise no name and no service UUID at all.
        if (nameFilter ?? "").isEmpty, let known = KnownAdapter.load(),
           let saved = list.first(where: { $0.peripheral.identifier == known.uuid }) {
            return saved
        }

        let filtered: [Candidate]
        if let filter = nameFilter, !filter.isEmpty {
            let needle = filter.lowercased()
            filtered = list.filter { $0.name.lowercased().contains(needle) }
        } else {
            filtered = list
        }

        let summary = filtered.isEmpty
            ? "Nothing seen nearby."
            : "Seen: " + filtered.map { $0.detail }.joined(separator: " | ")

        guard let best = filtered.max(by: { $0.score < $1.score }) else {
            throw BLEError.noDevice(summary)
        }

        // An explicit --device filter always wins; the heuristic only guards the
        // "pick something automatically" case.
        let explicit = !(nameFilter ?? "").isEmpty
        if !explicit && best.score < 50 {
            throw BLEError.noDevice(
                "Nothing looked like an OBD adapter. \(summary) Use --list to see names, or --device <name> to force one.")
        }

        return best
    }

    public func candidateList(seconds: TimeInterval) async throws -> [String] {
        let list = try await scan(seconds: seconds)
        return list.sorted { $0.score > $1.score }.map { $0.detail }
    }

    /// Drops the current link so another candidate can be tried.
    public func disconnect() {
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        port = nil

        lock.lock()
        rxBuffer.removeAll()
        let stalled = pending
        pending = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        lock.unlock()

        stalled?.resume(throwing: BLEError.notConnected)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertiseSerial = services.contains { $0 == Self.fff0 || $0 == Self.microchipService }

        if !name.isEmpty && !discoveredNames.contains(name) {
            discoveredNames.append(name)
        }

        var score = 0
        if advertiseSerial { score += 100 }
        let lower = name.lowercased()
        let keywords = ["obd", "elm", "vlink", "v-link", "icar", "vgate", "konnwei",
                        "veepeak", "linker", "carly", "viecar", "kfz", "scantool"]
        if keywords.contains(where: { lower.contains($0) }) { score += 60 }
        if !name.isEmpty { score += 5 }

        let detail = "\(name.isEmpty ? "(unnamed)" : name) rssi=\(RSSI)\(advertiseSerial ? " serial-advertised" : "")"
        let candidate = Candidate(peripheral: peripheral, name: name, score: score, rssi: RSSI.intValue, detail: detail)

        lock.lock()
        if let idx = candidates.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            if candidates[idx].score < score { candidates[idx] = candidate }
        } else {
            candidates.append(candidate)
        }
        lock.unlock()
    }

    // MARK: - Connection

    public func connect(_ candidate: Candidate) async throws -> SerialPort {
        guard let central else { throw BLEError.unavailable("not started") }

        adapterName = candidate.name
        adapterIdentifier = candidate.peripheral.identifier.uuidString

        let peripheral = candidate.peripheral
        self.peripheral = peripheral
        peripheral.delegate = self

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SerialPort, Error>) in
            lock.lock()
            readyCont = cont
            lock.unlock()
            central.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        failReady(BLEError.unavailable("could not connect: \(error?.localizedDescription ?? "unknown")"))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription ?? "link dropped"
        lock.lock()
        let waiting = pending
        pending = nil
        lock.unlock()
        waiting?.resume(throwing: BLEError.writeFailed("adapter disconnected: \(message)"))
        failReady(BLEError.writeFailed("adapter disconnected: \(message)"))
        onDisconnect?(message)
    }

    private func failReady(_ error: Error) {
        lock.lock()
        let cont = readyCont
        readyCont = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    // MARK: - Service / characteristic discovery

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failReady(BLEError.unavailable("service discovery failed: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            failReady(BLEError.noSerialPort)
            return
        }
        lock.lock()
        servicesRemaining = services.count
        lock.unlock()
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            onWarning?("characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
        }

        if service.uuid == Self.deviceInfoService {
            for ch in service.characteristics ?? [] where ch.properties.contains(.read) {
                peripheral.readValue(for: ch)
            }
        }

        lock.lock()
        servicesRemaining -= 1
        let done = servicesRemaining <= 0
        lock.unlock()

        if done { resolvePort() }
    }

    private func resolvePort() {
        guard let peripheral else {
            failReady(BLEError.notConnected)
            return
        }
        let services = peripheral.services ?? []

        func pick(_ uuid: CBUUID, label: String) -> SerialPort? {
            guard let service = services.first(where: { $0.uuid == uuid }),
                  let chars = service.characteristics, !chars.isEmpty
            else { return nil }

            let notify = chars.first {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            }
            let write = chars.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }
            guard let notify, let write else { return nil }

            // Prefer an acknowledged write when the characteristic allows it,
            // otherwise use the only mode it supports.
            let writeType: CBCharacteristicWriteType =
                write.properties.contains(.write) ? .withResponse : .withoutResponse

            return SerialPort(label: label, write: write, notify: notify, writeType: writeType)
        }

        let selected = pick(Self.fff0, label: "FFF0 / FFF1(notify) / FFF2(write)")
            ?? pick(Self.microchipService, label: "Microchip Transparent UART")

        guard let selected else {
            failReady(BLEError.noSerialPort)
            return
        }

        port = selected
        peripheral.setNotifyValue(true, for: selected.notify)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            failReady(BLEError.unavailable("could not subscribe to notifications: \(error.localizedDescription)"))
            return
        }
        guard characteristic.isNotifying, let port else { return }

        lock.lock()
        let cont = readyCont
        readyCont = nil
        lock.unlock()
        cont?.resume(returning: port)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }

        if characteristic.service?.uuid == Self.deviceInfoService {
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                deviceInfo[Self.infoName(characteristic.uuid)] = text
            }
            return
        }

        handleSerialData(data)
    }

    private static func infoName(_ uuid: CBUUID) -> String {
        switch uuid.uuidString.uppercased() {
        case "2A29": return "manufacturer"
        case "2A24": return "model"
        case "2A25": return "serialNumber"
        case "2A27": return "hardwareRevision"
        case "2A26": return "firmwareRevision"
        case "2A28": return "softwareRevision"
        default: return uuid.uuidString
        }
    }

    // MARK: - Prompt-delimited reads

    private func handleSerialData(_ data: Data) {
        lock.lock()
        rxBuffer.append(data)

        let text = String(decoding: rxBuffer, as: UTF8.self)
        guard let promptIndex = text.firstIndex(of: ">") else {
            lock.unlock()
            return
        }

        let chunk = String(text[...promptIndex])
        let remainder = String(text[text.index(after: promptIndex)...])
        rxBuffer = Data(remainder.utf8)

        let cont = pending
        pending = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        lock.unlock()

        cont?.resume(returning: chunk)
    }

    /// Sends a command and waits for the `>` prompt. Fully serialised.
    public func request(_ command: String, timeout: TimeInterval) async throws -> String {
        guard let peripheral, let port else { throw BLEError.notConnected }

        let payload = command.hasSuffix("\r") ? command : command + "\r"

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            lock.lock()
            if pending != nil {
                lock.unlock()
                cont.resume(throwing: BLEError.writeFailed("another request is already in flight"))
                return
            }
            pending = cont
            pendingCommand = command
            rxBuffer.removeAll()
            lock.unlock()

            let bytes = Data(payload.utf8)
            let chunkLimit = peripheral.maximumWriteValueLength(for: port.writeType)
            let maxChunk = max(1, chunkLimit)
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + maxChunk, bytes.count)
                peripheral.writeValue(bytes.subdata(in: offset..<end), for: port.write, type: port.writeType)
                offset = end
            }

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stalled = self.pending
                self.pending = nil
                self.rxBuffer.removeAll()
                self.lock.unlock()
                stalled?.resume(throwing: BLEError.timeout(command))
            }

            lock.lock()
            timeoutItem = item
            lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }
}
