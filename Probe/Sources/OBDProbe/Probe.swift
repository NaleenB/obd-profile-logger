import Foundation
import OBDCore
import OBDLink

struct PIDProbe {
    let pid: UInt8
    let name: String
    let detail: String
    var listed: Bool = false        // advertised in the supported bitmaps
    var responded: Bool = false     // actually returned data
    var rawHex: String = ""
    var decoded: String = ""
    var unit: String = ""
    var sample: [Double] = []
}

final class Probe {
    private let elm: ELMSource
    private let logger: SessionLogger

    private var adapter: [String: Any] = [:]
    private var vehicle: [String: Any] = [:]
    private var notes: [String] = []
    private var pidProbes: [PIDProbe] = []
    private var dtcs: [String: Any] = [:]
    private var connectedPortLabel = ""

    init(elm: ELMSource, logger: SessionLogger) {
        self.elm = elm
        self.logger = logger
    }

    // MARK: - Entry point

    func run(
        ignitionWait: TimeInterval,
        skipIgnition: Bool,
        portLabel: String,
        bleName: String,
        bleIdentifier: String,
        scanModules: Bool = true,
        liveSampleSeconds: TimeInterval = 20,
        mode22Seconds: TimeInterval = 150,
        sweepOnly: Bool = false,
        sweepService: UInt8 = 0x22
    ) async throws {
        connectedPortLabel = portLabel
        adapter["bleName"] = bleName.isEmpty ? "(unnamed)" : bleName
        adapter["bleIdentifier"] = bleIdentifier

        if sweepOnly {
            try await handshake()
            if skipIgnition {
                notes.append("Ignition wait skipped by request.")
            } else {
                _ = try await waitForECU(maxWait: ignitionWait)
            }
            try await pinProtocol()
            try await sweepIdentifiers(service: sweepService, budget: mode22Seconds)
            try await readDTCs()
            try writeOutputs()
            return
        }

        try await identifyAdapter()
        try await handshake()

        var batteryReport: BatteryReport?

        if skipIgnition {
            notes.append("Ignition wait skipped by request; results are adapter-only.")
        } else {
            batteryReport = try await awaitStart(maxWait: ignitionWait)
        }

        try await pinProtocol()
        try await readVehicleIdentity()
        try await readSupportedPIDs()
        try await smokeTestPIDs()
        try await readMode06()
        if liveSampleSeconds > 0 {
            try await liveSample(seconds: liveSampleSeconds)
        }
        try await readDTCs()

        // Headers-on scanning is deliberately last: on this adapter it leaves the
        // CAN receive filter latched to whichever module answered, which silently
        // hides every other module. Collect the real data first.
        if scanModules {
            try await identifyModules()
        }
        try await sweepIdentifiers(service: sweepService, budget: mode22Seconds)

        try writeOutputs(battery: batteryReport)
    }

    // MARK: - Adapter identity

    private func identifyAdapter() async throws {
        rule("Adapter")

        let ati = try? await elm.send("ATI")
        adapter["identity"] = ati?.statusSummary ?? "no response"
        say("  ATI    → \(ati?.statusSummary ?? "(no response)")")

        let at1 = try? await elm.send("AT@1")
        adapter["description"] = at1?.statusSummary ?? "no response"
        say("  AT@1   → \(at1?.statusSummary ?? "(no response)")")

        adapter["port"] = connectedPortLabel
        say("  Port   → \(connectedPortLabel)")
    }

    // MARK: - Handshake

    private func handshake() async throws {
        rule("Handshake")

        let reset = try await elm.send("ATZ", timeout: 6)
        say("  ATZ    → \(reset.statusSummary)")

        // Give the clone a moment after reset; some need it before accepting commands.
        try? await Task.sleep(nanoseconds: 400_000_000)

        for command in ["ATE0", "ATL0", "ATS0", "ATH0", "ATAR"] {
            let reply = try? await elm.send(command, timeout: 2.5)
            say("  \(command.padding(toLength: 7, withPad: " ", startingAt: 0))→ \(reply?.statusSummary ?? "(no reply)")")
        }
    }

    // MARK: - Ignition gate

    /// Waits for the driver to start the engine, measuring the battery across
    /// the whole start event as it happens. This replaces the old "poll until
    /// the ECU answers" gate: the start event *is* the gate, and the voltage
    /// trace across it is the most useful battery test available over OBD.
    private func awaitStart(maxWait: TimeInterval) async throws -> BatteryReport {
        rule("Start-up and battery")

        say("  Turn the ignition ON, then start the engine when you are ready.")
        say("  Sampling voltage and RPM continuously — no need to time anything.")
        say("")

        let monitor = BatteryMonitor()
        let began = Date()
        var iteration = 0
        var runningSince: Date?
        var lastPrintedPhase: BatteryPhase = .unknown
        var announcements: Set<BatteryPhase> = []

        while Date().timeIntervalSince(began) < maxWait {
            let elapsed = Int(Date().timeIntervalSince(began) * 1000)

            // RPM is sampled every sixth pass so voltage keeps the resolution
            // that matters during a crank.
            var rpm: Double?
            if iteration % 6 == 0 {
                if let reply = try? await elm.send("010C", timeout: 2),
                   let hex = reply.payloadHex, hex.hasPrefix("410C"),
                   let bytes = bytesFromHex(String(hex.dropFirst(4))), bytes.count >= 2 {
                    rpm = (Double(bytes[0]) * 256.0 + Double(bytes[1])) / 4.0
                }
            }

            var volts: Double?
            if let reply = try? await elm.send("0142", timeout: 2),
               let hex = reply.payloadHex, hex.hasPrefix("4142"),
               let bytes = bytesFromHex(String(hex.dropFirst(4))), bytes.count >= 2 {
                volts = (Double(bytes[0]) * 256.0 + Double(bytes[1])) / 1000.0
            }

            if let volts {
                monitor.ingest(VoltageSample(atMs: elapsed, volts: volts, rpm: rpm))
            }

            let phase = monitor.currentPhase

            if phase != lastPrintedPhase {
                switch phase {
                case .ignitionOn:
                    say("  [\(clockStamp())] ignition on, engine not turning")
                case .cranking:
                    say("  [\(clockStamp())] cranking detected — capturing minimum voltage")
                case .running:
                    say("  [\(clockStamp())] engine started")
                case .unknown:
                    break
                }
                lastPrintedPhase = phase
            }

            if phase == .running {
                if runningSince == nil { runningSince = Date() }
                if let since = runningSince, Date().timeIntervalSince(since) > 2.5 {
                    break
                }
            }

            if !announcements.contains(.ignitionOn), phase == .ignitionOn, iteration > 40,
               monitor.latestVolts == nil {
                say("  Waiting for the ECU to answer…")
                announcements.insert(.ignitionOn)
            }

            iteration += 1
        }

        let report = monitor.report()

        switch report.phaseReached {
        case .running:
            break
        case .ignitionOn:
            notes.append("No engine start was observed; the battery test is incomplete.")
            say("  No start observed — continuing with the remaining checks.")
        case .unknown, .cranking:
            throw ProbeError.ignitionTimeout(Int(maxWait))
        }

        say("")
        for finding in report.findings {
            say("  \(badge(finding.severity)) \(finding.label): \(finding.message)")
        }
        say("")

        return report
    }

    private func badge(_ severity: Severity) -> String {
        switch severity {
        case .ok: return "OK  "
        case .watch: return "WATCH"
        case .suspect: return "FAIL"
        case .insufficientData: return "n/a "
        }
    }

    private func waitForECU(maxWait: TimeInterval) async throws -> ELMResponse {
        say("")
        say("  ============================================================")
        say("    TURN THE IGNITION ON NOW")
        say("  ============================================================")
        say("  Waiting up to \(Int(maxWait))s for the engine ECU to answer 0100.")
        say("")

        let deadline = Date().addingTimeInterval(maxWait)
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            do {
                let reply = try await elm.send("0100", timeout: 10)
                if let hex = reply.payloadHex, hex.hasPrefix("4100"), hex.count >= 12 {
                    say("  [\(clockStamp())] ECU answered on attempt \(attempt): \(hex)")
                    vehicle["firstResponseAt"] = isoNow()
                    return reply
                }
                say("  [\(clockStamp())] attempt \(attempt): \(reply.statusSummary)")
            } catch {
                say("  [\(clockStamp())] attempt \(attempt): \(error)")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        throw ProbeError.ignitionTimeout(Int(maxWait))
    }

    // MARK: - Protocol

    private func pinProtocol() async throws {
        rule("Protocol")

        let dpn = try? await elm.send("ATDPN")
        say("  ATDPN  → \(dpn?.statusSummary ?? "(no reply)")")

        // Protocol 6 = ISO 15765-4 CAN, 11-bit, 500 kbps. Already observed on this car.
        let pinned = try? await elm.send("ATSP6", timeout: 3)
        say("  ATSP6  → \(pinned?.statusSummary ?? "(no reply)")")

        let dp = try? await elm.send("ATDP")
        say("  ATDP   → \(dp?.statusSummary ?? "(no reply)")")

        let voltage = try? await elm.send("ATRV")
        say("  ATRV   → \(voltage?.statusSummary ?? "(no reply)")")

        adapter["protocolNumber"] = dpn?.statusSummary ?? ""
        adapter["protocolDescription"] = dp?.statusSummary ?? ""
        adapter["batteryVoltage"] = voltage?.statusSummary ?? ""

        // Re-confirm the ECU still answers with the protocol pinned.
        if let reply = try? await elm.send("0100", timeout: 8),
           let hex = reply.payloadHex, hex.hasPrefix("4100") {
            say("  Re-check 0100 → \(hex)")
        } else {
            notes.append("ECU did not answer 0100 after pinning ATSP6; results below may be incomplete.")
            say("  Re-check 0100 → no answer (continuing)")
        }
    }

    // MARK: - Module identification

    /// Switches headers on for a handful of queries so we can see which CAN IDs
    /// answer. Multiple modules replying to a broadcast mode 01 request is the
    /// reason frames must stay separate.
    private func identifyModules() async throws {
        rule("Module identification (headers on)")

        _ = try? await elm.send("ATH1", timeout: 3)

        var scan: [String: [String]] = [:]
        for command in ["0100", "010C", "0101", "03"] {
            guard let reply = try? await elm.send(command, timeout: 8) else {
                say("  \(command) → no reply")
                continue
            }
            let visible = reply.lines.filter { !$0.isEmpty }
            scan[command] = visible
            say("  \(command) →")
            for line in visible { say("      \(line)") }
        }

        adapter["moduleScan"] = scan

        // Turning headers on latches the clone's CAN receive filter to the last
        // module that answered. Clear it explicitly and verify.
        _ = try? await elm.send("ATAR", timeout: 3)
        _ = try? await elm.send("ATSH7DF", timeout: 3)
        _ = try? await elm.send("ATH0", timeout: 3)
        _ = try? await elm.send("ATSP6", timeout: 3)

        if let check = try? await elm.send("0100", timeout: 6) {
            let frames = check.payloadFrames.count
            say("")
            say("  Filter restored: 0100 returned \(frames) frame(s)")
            for frame in check.payloadFrames { say("      \(frame)") }
            if frames < 2 {
                notes.append("After the headers-on scan, only one module answered; "
                             + "the adapter's receive filter may still be latched.")
            }
        }

        // Can we address the engine ECU directly? If this works it removes the
        // ambiguity of two modules answering every broadcast request.
        say("")
        say("  ECM targeting test (ATSH 7E0)")
        _ = try? await elm.send("ATH1", timeout: 3)
        _ = try? await elm.send("ATSH7E0", timeout: 3)
        var targeting: [String: Any] = [:]
        for command in ["0100", "010C", "0104"] {
            if let reply = try? await elm.send(command, timeout: 6) {
                let visible = reply.lines.filter { !$0.isEmpty }.joined(separator: " | ")
                say("    \(command) → \(visible)")
                targeting[command] = visible
            } else {
                say("    \(command) → no reply")
            }
        }
        adapter["ecmTargeting"] = targeting

        _ = try? await elm.send("ATAR", timeout: 3)
        _ = try? await elm.send("ATSH7DF", timeout: 3)
        _ = try? await elm.send("ATH0", timeout: 3)
        say("")
        say("  Headers off again; probe complete.")
    }

    // MARK: - Vehicle identity (mode 09)
    private func readVehicleIdentity() async throws {
        rule("Vehicle identity (mode 09)")

        if let vin = await mode09(pid: 0x02, label: "VIN") {
            vehicle["vin"] = vin
            say("  VIN    → \(vin)")
        } else {
            notes.append("VIN (mode 09 PID 02) unavailable; common on v1.5 clones due to multi-frame handling.")
            say("  VIN    → unavailable")
        }

        if let calid = await mode09(pid: 0x04, label: "Calibration ID") {
            vehicle["calibrationID"] = calid
            say("  CalID  → \(calid)")
        } else {
            say("  CalID  → unavailable")
        }

        if let cvn = await mode09(pid: 0x06, label: "CVN") {
            vehicle["cvn"] = cvn
            say("  CVN    → \(cvn)")
        } else {
            say("  CVN    → unavailable")
        }

        if let ecuName = await mode09(pid: 0x0A, label: "ECU name") {
            vehicle["ecuName"] = ecuName
            say("  ECU    → \(ecuName)")
        } else {
            say("  ECU name → unavailable")
        }

        if let ipt = await mode09(pid: 0x08, label: "In-use performance tracking") {
            vehicle["inUsePerformanceTracking"] = ipt
            say("  IPT    → \(ipt)")
        } else {
            say("  IPT    → unavailable")
        }
    }

    // MARK: - Mode 06

    /// On-board monitoring test results. Closest generic-OBD substitute for the
    /// manufacturer-specific DPF and aftertreatment data this car does not expose.
    private func readMode06() async throws {
        rule("Mode 06 on-board monitor results")

        guard let reply = try? await elm.send("0600", timeout: 6),
              let hex = reply.payloadHex, hex.hasPrefix("4600")
        else {
            say("  Not supported by this ECU.")
            notes.append("Mode 06 (on-board monitoring) unavailable.")
            return
        }

        guard let bytes = bytesFromHex(String(hex.dropFirst(4))), bytes.count >= 4 else {
            say("  Short reply: \(hex)")
            return
        }

        let mids = Probe.expandBitmap(Array(bytes.prefix(4)), base: 0x00)
        say("  Supported MIDs: " + (mids.isEmpty ? "none" : mids.map { String(format: "%02X", $0) }.joined(separator: " ")))

        var results: [String: String] = [:]
        for mid in mids.prefix(40) {
            let command = String(format: "06%02X", mid)
            if let r = try? await elm.send(command, timeout: 3), let h = r.payloadHex {
                results[String(format: "%02X", mid)] = h
                say(String(format: "  MID %02X → %@", mid, h))
            } else {
                say(String(format: "  MID %02X → no data", mid))
            }
        }
        vehicle["mode06"] = results
    }

    // MARK: - DPF sensor check

    /// Characterises the exhaust differential-pressure sensor.
    ///
    /// The two soot estimators disagree by a factor of nine on this car (2.6 and
    /// 0.3 g/L). That is either a decode fault in the differential-pressure path
    /// or a hardware fact, and this tells you which: a working sensor reads
    /// roughly zero with no flow, rises at idle, and rises further with RPM.
    func runDPFCheck(profile: VehicleProfile, secondsPerPhase: TimeInterval) async throws {
        rule("DPF differential-pressure check")

        guard let sensor = profileParameter(profile, item: 120),
              let sootDiff = profileParameter(profile, item: 156) else {
            throw ProbeError.noData("profile does not define items 120 and 156")
        }

        func read(rpm: Double?) async -> (dp: Double?, soot: Double?) {
            _ = try? await elm.send("ATSH7E0", timeout: 2)
            let reply = try? await elm.send("2110", timeout: 3)
            _ = try? await elm.send("ATSH7DF", timeout: 2)
            guard let hex = reply?.payloadHex, let frame = MUT21Frame(hex: hex) else {
                return (nil, nil)
            }
            let values = profile.decode(frame)
            let dp = values.first { $0.itemNumber == 120 }?.value
            let soot = values.first { $0.itemNumber == 156 }?.value
            return (dp, soot)
        }

        func rpmNow() async -> Double? {
            guard let reply = try? await elm.send("010C", timeout: 2),
                  let hex = reply.payloadHex, hex.hasPrefix("410C"),
                  let bytes = bytesFromHex(String(hex.dropFirst(4))), bytes.count >= 2
            else { return nil }
            return (Double(bytes[0]) * 256.0 + Double(bytes[1])) / 4.0
        }

        func phase(_ title: String, samples: Int) async -> [Double] {
            say("")
            say("  \(title)")
            var collected: [Double] = []
            for index in 0..<samples {
                let rpm = await rpmNow()
                let result = await read(rpm: rpm)
                if let dp = result.dp {
                    collected.append(dp)
                    say(String(format: "    %2d  %6.0f rpm   dP %6.2f kPa   soot(dP) %5.2f g/L",
                               index + 1, rpm ?? 0, dp, result.soot ?? 0))
                } else {
                    say("    \(index + 1)  no reply")
                }
                try? await Task.sleep(nanoseconds: UInt64(secondsPerPhase / Double(samples) * 1_000_000_000))
            }
            return collected
        }

        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        say("")
        say("  Phase 1 — ignition ON, engine OFF. Do not start the engine yet.")
        let off = await phase("No flow (sensor zero)", samples: 6)

        say("")
        say("  Phase 2 — START THE ENGINE now and leave it idling.")
        say("  Waiting for the engine to catch…")
        for _ in 0..<30 {
            if let rpm = await rpmNow(), rpm > 400 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let idle = await phase("Idle", samples: 8)

        say("")
        say("  Phase 3 — HOLD THE ENGINE AT ABOUT 2500 RPM until this finishes.")
        let revved = await phase("Raised RPM", samples: 8)

        let zero = median(off)
        let atIdle = median(idle)
        let atRev = median(revved)

        rule("Result")
        say(String(format: "  no flow     %@", zero.map { String(format: "%.2f kPa", $0) } ?? "no data"))
        say(String(format: "  idle        %@", atIdle.map { String(format: "%.2f kPa", $0) } ?? "no data"))
        say(String(format: "  ~2500 rpm   %@", atRev.map { String(format: "%.2f kPa", $0) } ?? "no data"))

        var notesOut: [String] = []
        if let zero {
            let ok = abs(zero) <= 2.5
            say("  \(ok ? "OK  " : "FAIL") sensor zero within the +-2.5 kPa specification"
                + (ok ? "" : " — the sensor or its wiring is suspect"))
            notesOut.append("zero=\(zero)")
        } else {
            say("  FAIL no reading with no flow")
        }

        if let zero, let atRev {
            let rise = atRev - zero
            let responds = rise > 0.5
            say("  \(responds ? "OK  " : "FAIL") rises with exhaust flow (+\(String(format: "%.2f", rise)) kPa)")
            if !responds {
                say("        A sensor that does not move with flow cannot produce a soot estimate.")
                say("        Treat the differential-pressure soot figure as unreliable.")
            }
        }

        vehicle["dpfCheck"] = [
            "noFlowKPa": zero ?? 0,
            "idleKPa": atIdle ?? 0,
            "raisedRPMKPa": atRev ?? 0,
            "sensorItem": sensor.itemNumber ?? 0,
            "sootItem": sootDiff.itemNumber ?? 0
        ]
        _ = notesOut
    }

    private func profileParameter(_ profile: VehicleProfile, item: Int) -> VehicleProfile.Parameter? {
        profile.blocks.flatMap(\.parameters).first { $0.itemNumber == item }
    }

    // MARK: - Mode 22 sweep

    /// Read-only sweep of the UDS identifier space on the engine ECU.
    ///
    /// Nothing here writes to the ECU: 0x22 is ReadDataByIdentifier, 0x21 is
    /// ReadDataByLocalIdentifier, 0x1A is ReadECUIdentification. All read-only.
    private func sweepIdentifiers(service: UInt8, budget: TimeInterval) async throws {
        let serviceName = String(format: "%02X", service)
        rule("Service \(serviceName) identifier sweep (read-only)")

        guard budget > 0 else {
            say("  Skipped.")
            return
        }

        _ = try? await elm.send("ATH0", timeout: 3)
        _ = try? await elm.send("ATSP6", timeout: 3)
        _ = try? await elm.send("ATSH7E0", timeout: 3)

        var positive: [String: String] = [:]
        var nrcCounts: [String: Int] = [:]
        var silent = 0
        var tried = 0
        let expectedReply = String(format: "%02X", service &+ 0x40)
        let start = Date()

        let identifiers: [(UInt16, String)] = {
            switch service {
            case 0x22:
                var list: [(UInt16, String)] = []
                for (low, high) in [(UInt16(0xF100), UInt16(0xF1FF)),
                                    (0x0100, 0x01FF),
                                    (0x0200, 0x02FF),
                                    (0x1000, 0x10FF),
                                    (0x2000, 0x20FF),
                                    (0x3000, 0x30FF)] {
                    for did in low...high { list.append((did, String(format: "%04X", did))) }
                }
                return list
            default:
                // 0x21 and 0x1A take a single-byte local identifier.
                return (0...0xFF).map { (UInt16($0), String(format: "%02X", $0)) }
            }
        }()

        sweep: for (_, identifier) in identifiers {
            if Date().timeIntervalSince(start) > budget { break sweep }

            let command = serviceName + identifier
            tried += 1

            guard let reply = try? await elm.send(command, timeout: 1.2),
                  let hex = reply.payloadHex
            else {
                silent += 1
                continue
            }

            if hex.hasPrefix(expectedReply) {
                positive[identifier] = hex
            } else if hex.hasPrefix("7F") {
                // 7F <service> <NRC> — classify the negative response code.
                let nrc = String(hex.dropFirst(4).prefix(2))
                nrcCounts[nrc, default: 0] += 1
            } else {
                silent += 1
            }

            if tried % 64 == 0 {
                sayInline("    … \(tried) tried, \(positive.count) answered\r")
            }
        }

        _ = try? await elm.send("ATSH7DF", timeout: 3)
        _ = try? await elm.send("ATAR", timeout: 3)
        _ = try? await elm.send("ATH0", timeout: 3)

        say("  \(tried) identifiers tried in \(Int(Date().timeIntervalSince(start)))s")
        say("  \(positive.count) answered, \(silent) silent")
        for (nrc, count) in nrcCounts.sorted(by: { $0.key < $1.key }) {
            say("  \(count) rejected: NRC \(nrc) — \(Probe.nrcMeaning(nrc))")
        }

        for key in positive.keys.sorted() {
            let value = positive[key] ?? ""
            say("    \(key) → \(value.prefix(64))")
        }

        if positive.isEmpty {
            notes.append("Service \(serviceName) sweep found no identifiers on 7E0.")
        }

        var summary: [String: Any] = [
            "service": serviceName,
            "tried": tried,
            "answered": positive,
            "silent": silent,
            "budgetSeconds": budget
        ]
        summary["nrc"] = nrcCounts
        vehicle["sweep_" + serviceName] = summary
    }

    static func nrcMeaning(_ code: String) -> String {
        switch code.uppercased() {
        case "10": return "general reject"
        case "11": return "service not supported by this ECU"
        case "12": return "sub-function not supported"
        case "13": return "incorrect message length"
        case "21": return "busy, repeat request"
        case "22": return "conditions not correct"
        case "31": return "request out of range"
        case "33": return "security access denied"
        case "7E": return "sub-function not supported in this session"
        case "7F": return "service not supported in this session"
        default: return "unknown"
        }
    }

    // MARK: - Live sample

    /// Records a short streaming sample. Confirms the adapter sustains a usable
    /// rate, and gives the app a real number to design its polling loop around.
    private func liveSample(seconds: TimeInterval) async throws {
        rule("Live sample (\(Int(seconds))s)")

        let core: [UInt8] = [0x0C, 0x0D, 0x05, 0x0B, 0x10, 0x11, 0x04, 0x23, 0x42, 0x0F, 0x2F, 0x33]
        let available = pidProbes.filter { $0.responded && core.contains($0.pid) }
        guard !available.isEmpty else {
            say("  No core PIDs available to sample.")
            return
        }

        say("  Sampling: " + available.map { String(format: "%02X", $0.pid) }.joined(separator: " "))
        let start = Date()
        var counts: [UInt8: Int] = [:]
        var reads = 0

        while Date().timeIntervalSince(start) < seconds {
            for probe in available {
                let command = String(format: "01%02X", probe.pid)
                guard let reply = try? await elm.send(command, timeout: 2),
                      let hex = reply.payloadHex,
                      hex.hasPrefix(String(format: "41%02X", probe.pid))
                else { continue }

                let bytes = bytesFromHex(String(hex.dropFirst(4))) ?? []
                let value = PIDTable.decode(pid: probe.pid, data: bytes)?.value
                logger.raw([
                    "t": isoNow(),
                    "sample": String(format: "%02X", probe.pid),
                    "hex": hex,
                    "value": value.map { String($0) } ?? "",
                    "ms": Int(Date().timeIntervalSince(start) * 1000)
                ])
                counts[probe.pid, default: 0] += 1
                reads += 1
            }
        }

        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        say("  \(reads) reads in \(String(format: "%.1f", elapsed))s → \(String(format: "%.1f", Double(reads) / elapsed)) reads/s")
        for (pid, count) in counts.sorted(by: { $0.key < $1.key }) {
            say(String(format: "    %02X %@: %d samples (%.2f Hz)",
                       pid, PIDTable.name(pid), count, Double(count) / elapsed))
        }

        vehicle["liveSample"] = [
            "reads": reads,
            "seconds": elapsed,
            "perPID": counts.reduce(into: [String: Int]()) { $0[String(format: "%02X", $1.key)] = $1.value }
        ]
    }

    private func mode09(pid: UInt8, label: String) async -> String? {
        let command = String(format: "09%02X", pid)
        guard let reply = try? await elm.send(command, timeout: 8),
              let hex = reply.payloadFrames.first
        else { return nil }

        let header = String(format: "49%02X", pid)
        guard hex.hasPrefix(header) else { return nil }

        let tail = String(hex.dropFirst(header.count))
        guard let bytes = bytesFromHex(tail), bytes.count > 1 else { return nil }

        // CVN and in-use performance tracking are binary, not ASCII.
        if pid == 0x06 || pid == 0x08 {
            return hexString(Array(bytes.dropFirst()))
        }

        // Byte 0 is the frame counter; the value is ASCII padded with 0x00.
        let payload = bytes.dropFirst().prefix { $0 != 0x00 }.filter { $0 >= 0x20 && $0 < 0x7F }
        let text = String(decoding: payload, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: - Supported PID discovery

    private func readSupportedPIDs() async throws {
        rule("Supported PIDs (bitmaps)")

        var all: Set<UInt8> = []
        var blocks: [[String: Any]] = []

        for base in stride(from: 0, through: 0xC0, by: 0x20) {
            let pid = UInt8(base)
            let command = String(format: "01%02X", pid)
            guard let reply = try? await elm.send(command, timeout: 6) else {
                say("  \(command) → no reply")
                continue
            }
            guard let hex = reply.payloadHex else {
                say("  \(command) → \(reply.statusSummary)")
                continue
            }

            let header = String(format: "41%02X", pid)
            guard hex.hasPrefix(header) else {
                say("  \(command) → unexpected: \(hex)")
                continue
            }

            let tail = String(hex.dropFirst(header.count))
            guard let bytes = bytesFromHex(tail), bytes.count >= 4 else {
                say("  \(command) → short: \(hex)")
                continue
            }

            let bitmap = Array(bytes.prefix(4))
            let supported = Probe.expandBitmap(bitmap, base: pid)
            all.formUnion(supported)

            blocks.append([
                "command": command,
                "bitmap": hexString(bitmap),
                "pids": supported.map { String(format: "%02X", $0) }
            ])

            let preview = supported.map { String(format: "%02X", $0) }.joined(separator: " ")
            say("  \(command) → \(hexString(bitmap))")
            say("        \(preview.isEmpty ? "(none)" : preview)")

            if bytes.allSatisfy({ $0 == 0 }) { break }
        }

        vehicle["supportedPIDBlocks"] = blocks

        // PIDs in the bitmap chain are markers for the next block, not real data.
        let chainMarkers: Set<UInt8> = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0]
        let candidates = all.subtracting(chainMarkers).sorted()

        pidProbes = candidates.map {
            PIDProbe(pid: $0, name: PIDTable.name($0), detail: PIDTable.detail($0), listed: true)
        }

        say("")
        say("  \(candidates.count) PIDs advertised by the ECU.")
    }

    static func expandBitmap(_ bitmap: [UInt8], base: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        for (byteIndex, byte) in bitmap.enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let value = Int(base) + byteIndex * 8 + bit + 1
                if value <= 0xFF { out.append(UInt8(value)) }
            }
        }
        return out
    }

    // MARK: - Per-PID smoke test

    private func smokeTestPIDs() async throws {
        rule("PID smoke test (one read each)")

        var updated: [PIDProbe] = []

        for var probe in pidProbes {
            let command = String(format: "01%02X", probe.pid)
            let header = String(format: "41%02X", probe.pid)

            guard let reply = try? await elm.send(command, timeout: 2.5) else {
                updated.append(probe)
                say("  \(command)  \(pad(probe.name, 24)) → timeout")
                continue
            }

            guard let hex = reply.payloadHex, hex.hasPrefix(header) else {
                updated.append(probe)
                say("  \(command)  \(pad(probe.name, 24)) → \(reply.statusSummary)")
                continue
            }

            let tail = String(hex.dropFirst(header.count))
            let bytes = bytesFromHex(tail) ?? []
            probe.responded = true
            probe.rawHex = hex

            if let decoded = PIDTable.decode(pid: probe.pid, data: bytes) {
                probe.decoded = formatValue(decoded.value)
                probe.unit = decoded.unit
                probe.sample = [decoded.value]
                say("  \(command)  \(pad(probe.name, 24)) → \(pad(hex, 18)) \(probe.decoded) \(probe.unit)")
            } else {
                say("  \(command)  \(pad(probe.name, 24)) → \(pad(hex, 18)) (raw)")
            }

            updated.append(probe)
        }

        pidProbes = updated
    }

    // MARK: - DTCs

    /// Queries each module by name rather than trusting one broadcast reply.
    ///
    /// Both the engine (7E8) and transmission (7E9) answer generic OBD on this
    /// vehicle. Addressing them individually keeps each module's codes attached
    /// to that module, and lets the report say when a module did not answer
    /// instead of implying a clean bill of health.
    private func readDTCs() async throws {
        rule("Diagnostic trouble codes")

        let targets: [(module: String, header: String)] = [
            ("ECM", "7E0"),
            ("TCM", "7E1")
        ]

        _ = try? await elm.send("ATH0", timeout: 3)

        var modules: [ModuleDiagnostics] = []

        for target in targets {
            _ = try? await elm.send("ATSH" + target.header, timeout: 3)

            var milOn: Bool?
            var reported: Int?

            if let reply = try? await elm.send("0101", timeout: 3),
               let hex = reply.payloadHex, hex.hasPrefix("4101"),
               let bytes = bytesFromHex(String(hex.dropFirst(4))), bytes.count >= 2 {
                milOn = (bytes[0] & 0x80) != 0
                reported = Int(bytes[0] & 0x7F)
            }

            let stored = await queryCodes(mode: "03")
            let pending = await queryCodes(mode: "07")
            let permanent = await queryCodes(mode: "0A")

            let module = ModuleDiagnostics(
                module: target.module,
                header: target.header,
                milOn: milOn,
                reportedDTCs: reported,
                stored: stored,
                pending: pending,
                permanent: permanent
            )
            modules.append(module)

            let milText = milOn.map { $0 ? "ON" : "off" } ?? "unknown"
            say("  \(target.module) (7E\(target.header.hasSuffix("0") ? "8" : "9"))  MIL \(milText), \(reported ?? -1) reported")
            say("      stored:    \(describe(stored))")
            say("      pending:   \(describe(pending))")
            say("      permanent: \(describe(permanent))")
            if !module.isComplete {
                say("      ! incomplete — a query did not answer or could not be decoded")
            }
        }

        // Restore broadcast addressing.
        _ = try? await elm.send("ATSH7DF", timeout: 3)
        _ = try? await elm.send("ATAR", timeout: 3)

        let diagnostics = VehicleDiagnostics(modules: modules)
        say("")
        say("  \(diagnostics.headline)")

        dtcs = [
            "complete": diagnostics.isComplete,
            "incompleteModules": diagnostics.modulesIncomplete,
            "modules": modules.map { module -> [String: Any] in
                var entry: [String: Any] = [
                    "module": module.module,
                    "header": module.header,
                    "complete": module.isComplete
                ]
                if let value = module.milOn { entry["milOn"] = value }
                if let value = module.reportedDTCs { entry["reportedDTCs"] = value }
                entry["stored"] = module.stored ?? []
                entry["pending"] = module.pending ?? []
                entry["permanent"] = module.permanent ?? []
                return entry
            }
        ]

        // Freeze frame, if any. Broadcast is fine: it is not a per-module query.
        if let reply = try? await elm.send("0200", timeout: 5), let hex = reply.payloadHex {
            dtcs["freezeFramePID00"] = hex
            say("  Freeze frame → \(hex)")
        }
    }

    /// Returns decoded codes, or nil when the module did not answer or the reply
    /// could not be interpreted.
    private func queryCodes(mode: String) async -> [String]? {
        guard let reply = try? await elm.send(mode, timeout: 5),
              let hex = reply.payloadHex
        else { return nil }

        let header = "4" + String(mode.suffix(1))
        guard hex.hasPrefix(header) else { return nil }
        return DTCDecoder.codes(fromHex: String(hex.dropFirst(header.count)))
    }

    private func describe(_ codes: [String]?) -> String {
        guard let codes else { return "no answer" }
        return codes.isEmpty ? "none" : codes.joined(separator: ", ")
    }

    // MARK: - Output

    private func writeOutputs(battery: BatteryReport? = nil) throws {
        let supported = pidProbes.filter { $0.responded }
        let advertisedOnly = pidProbes.filter { !$0.responded }

        var dieselHighlights: [String] = []
        for interesting: UInt8 in [0x78, 0x79, 0x7A, 0x7C, 0x5C, 0x23, 0x83, 0x85] {
            let hit = pidProbes.first { $0.pid == interesting }
            if let hit, hit.responded {
                dieselHighlights.append(String(format: "%02X %@", interesting, hit.name))
            }
        }

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": isoNow(),
            "tool": "OBDProbe 0.1.0",
            "adapter": adapter,
            "vehicle": vehicle,
            "serialPort": connectedPortLabel,
            "deviceInfo": deviceInfoDictionary(),
            "supportedPIDCount": supported.count,
            "advertisedButSilent": advertisedOnly.map { String(format: "%02X", $0.pid) },
            "pids": pidProbes.map { probe -> [String: Any] in
                var entry: [String: Any] = [
                    "pid": String(format: "%02X", probe.pid),
                    "name": probe.name,
                    "detail": probe.detail,
                    "advertised": probe.listed,
                    "responded": probe.responded
                ]
                if probe.responded {
                    entry["raw"] = probe.rawHex
                    if !probe.decoded.isEmpty {
                        entry["value"] = probe.decoded
                        entry["unit"] = probe.unit
                    }
                }
                return entry
            },
            "dtcs": dtcs,
            "battery": battery.map(batteryDictionary) ?? [:],
            "dieselHighlights": dieselHighlights,
            "notes": notes
        ]

        try logger.writeJSON("probe.json", payload)
        try logger.write("report.txt", renderReport(dieselHighlights: dieselHighlights,
                                                     supported: supported,
                                                     advertisedOnly: advertisedOnly,
                                                     battery: battery))
        logger.close()

        rule("Done")
        say("  Written to: \(logger.directory.path)")
        say("    probe.json   machine-readable capability map")
        say("    report.txt   this summary")
        say("    raw_log.ndjson  every command and response, with timings")
        say("")
    }

    private var deviceInfoStore: [String: String] = [:]

    func attach(deviceInfo: [String: String]) {
        deviceInfoStore = deviceInfo
    }

    private func deviceInfoDictionary() -> [String: String] { deviceInfoStore }

    private func renderReport(
        dieselHighlights: [String],
        supported: [PIDProbe],
        advertisedOnly: [PIDProbe],
        battery: BatteryReport?
    ) -> String {
        var lines: [String] = []
        let stamp = isoNow()

        lines.append("OBDProbe report")
        lines.append("Generated: \(stamp)")
        lines.append("")
        lines.append("ADAPTER")
        for key in adapter.keys.sorted() {
            lines.append("  \(key): \(adapter[key] ?? "")")
        }
        for key in deviceInfoStore.keys.sorted() {
            lines.append("  ble.\(key): \(deviceInfoStore[key] ?? "")")
        }
        lines.append("")
        lines.append("VEHICLE")
        for key in vehicle.keys.sorted() where key != "supportedPIDBlocks" {
            lines.append("  \(key): \(vehicle[key] ?? "")")
        }
        lines.append("")
        lines.append("BATTERY")
        if let battery {
            lines.append("  phase reached: \(battery.phaseReached.rawValue)")
            lines.append("  samples: \(battery.sampleCount)")
            if let v = battery.preCrankVolts { lines.append(String(format: "  before crank: %.1f V", v)) }
            if let v = battery.crankMinimumVolts { lines.append(String(format: "  crank minimum: %.1f V", v)) }
            if let v = battery.crankDurationMs { lines.append("  crank duration: \(v) ms") }
            if let v = battery.runningVolts { lines.append(String(format: "  running: %.2f V", v)) }
            if let v = battery.recoveryMs { lines.append("  recovery: \(v) ms") }
            for finding in battery.findings {
                lines.append("  [\(finding.severity.rawValue)] \(finding.label): \(finding.message)")
            }
        } else {
            lines.append("  not measured this run")
        }
        lines.append("")
        lines.append("DIESEL-RELEVANT PIDs THAT RESPONDED")
        if dieselHighlights.isEmpty {
            lines.append("  none")
        } else {
            for item in dieselHighlights { lines.append("  \(item)") }
        }
        lines.append("")
        lines.append("RESPONDING PIDs (\(supported.count))")
        for probe in supported {
            let value = probe.decoded.isEmpty ? "(raw)" : "\(probe.decoded) \(probe.unit)"
            lines.append("  " + String(format: "%02X", probe.pid) + "  " + pad(probe.name, 24) + " " + probe.rawHex + "  " + value)
        }
        lines.append("")
        lines.append("ADVERTISED BUT SILENT (\(advertisedOnly.count))")
        for probe in advertisedOnly {
            lines.append(String(format: "  %02X  %@", probe.pid, probe.name))
        }
        lines.append("")
        lines.append("DTCs")
        lines.append("  \(dtcs)")
        lines.append("")
        lines.append("NOTES")
        for note in notes { lines.append("  - \(note)") }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting helpers

    private func batteryDictionary(_ report: BatteryReport) -> [String: Any] {
        var out: [String: Any] = [
            "phaseReached": report.phaseReached.rawValue,
            "sampleCount": report.sampleCount,
            "verdict": report.verdict.rawValue,
            "findings": report.findings.map { finding -> [String: Any] in
                var entry: [String: Any] = [
                    "key": finding.key,
                    "label": finding.label,
                    "severity": finding.severity.rawValue,
                    "message": finding.message
                ]
                if let observed = finding.observed { entry["observed"] = observed }
                return entry
            }
        ]
        if let value = report.preCrankVolts { out["preCrankVolts"] = value }
        if let value = report.crankMinimumVolts { out["crankMinimumVolts"] = value }
        if let value = report.crankDurationMs { out["crankDurationMs"] = value }
        if let value = report.runningVolts { out["runningVolts"] = value }
        if let value = report.recoveryMs { out["recoveryMs"] = value }
        return out
    }

    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func formatValue(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
