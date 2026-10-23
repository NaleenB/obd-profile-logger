import Foundation
import Darwin

@main
struct ProbeApp {

    struct Options {
        var scanSeconds: Double = 6
        var device: String? = nil
        var ignitionWait: Double = 180
        var skipIgnition = false
        var outDir: String? = nil
        var selfTest = false
        var listOnly = false
        var replayPath: String? = nil
        var scanTimeout: Double = 90
        var sampleSeconds: Double = 20
        var mode22Seconds: Double = 150
        var sweepOnly = false
        var sweepService: UInt8 = 0x22
    }

    static func main() async {
        let options = parseArguments()

        if options.selfTest {
            runSelfTest()
            exit(0)
        }

        say("OBDProbe 0.1.0  —  BLE ELM327 capability probe")
        say("")

        let transport = BLETransport()
        let logger: SessionLogger
        do {
            logger = try makeLogger(override: options.outDir)
        } catch {
            sayErr("Could not create results folder: \(error)")
            exit(1)
        }

        // `exit()` does not run defer blocks, so teardown is explicit.
        func finish(_ code: Int32) -> Never {
            try? logger.writeJSON("scan.json", transport.lastScanDetails)
            transport.shutdown()
            logger.close()
            exit(code)
        }

        if let replayPath = options.replayPath {
            do {
                let replay = try ReplayELM(logURL: URL(fileURLWithPath: replayPath))
                say("Replaying \(replay.commandCount) recorded commands")
                say("  from \(replayPath)")
                say("")
                let probe = Probe(elm: replay, logger: logger)
                try await probe.run(
                    ignitionWait: 0,
                    skipIgnition: true,
                    portLabel: "replay",
                    bleName: "",
                    bleIdentifier: "",
                    scanModules: false,
                    liveSampleSeconds: 0
                )
                finish(0)
            } catch {
                sayErr("FAILED: \(error)")
                finish(4)
            }
        }

        do {
            try await transport.start()
            say("Bluetooth ready.")

            if options.listOnly {
                say("Scanning for \(Int(options.scanSeconds))s...")
                let list = try await transport.candidateList(seconds: options.scanSeconds)
                say("")
                if list.isEmpty {
                    say("No BLE devices seen.")
                } else {
                    say("BLE devices, best first:")
                    for item in list { say("  \(item)") }
                    say("")
                    say("Force one with: ./run.sh --device <part of name>")
                }
                finish(0)
            }

            say("Scanning for \(Int(options.scanSeconds))s...")
            let (candidate, port) = try await acquireAdapter(transport: transport, logger: logger, options: options)

            KnownAdapter.save(uuid: candidate.peripheral.identifier, name: candidate.name)
            say("Found: \(candidate.name.isEmpty ? "(unnamed)" : candidate.name) [\(candidate.peripheral.identifier.uuidString.prefix(8))]")
            say("Serial port: \(port.label)")

            // Give the module a beat to settle before the first command.
            try? await Task.sleep(nanoseconds: 500_000_000)

            let elm = ELMClient(transport: transport, logger: logger)
            let probe = Probe(elm: elm, logger: logger)
            probe.attach(deviceInfo: transport.deviceInfo)

            if !transport.deviceInfo.isEmpty {
                say("")
                say("BLE device information:")
                for key in transport.deviceInfo.keys.sorted() {
                    say("  \(key): \(transport.deviceInfo[key] ?? "")")
                }
            }

            try await probe.run(
                ignitionWait: options.ignitionWait,
                skipIgnition: options.skipIgnition,
                portLabel: port.label,
                bleName: candidate.name,
                bleIdentifier: candidate.peripheral.identifier.uuidString,
                liveSampleSeconds: options.sampleSeconds,
                mode22Seconds: options.mode22Seconds,
                sweepOnly: options.sweepOnly,
                sweepService: options.sweepService
            )

            finish(0)
        } catch let error as ProbeError {
            say("")
            sayErr("FAILED: \(error.description)")
            logger.raw(["t": isoNow(), "error": error.description])
            finish(2)
        } catch let error as BLEError {
            say("")
            sayErr("FAILED: \(error.description)")
            finish(3)
        } catch {
            say("")
            sayErr("FAILED: \(error)")
            finish(4)
        }
    }

    // MARK: - Arguments

    static func parseArguments() -> Options {
        var options = Options()
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0

        func next() -> String? {
            index += 1
            return index < args.count ? args[index] : nil
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--self-test", "--selftest":
                options.selfTest = true
            case "--list", "--list-devices":
                options.listOnly = true
            case "--replay":
                options.replayPath = next()
            case "--scan-timeout":
                if let value = next(), let parsed = Double(value) { options.scanTimeout = parsed }
            case "--sample-seconds":
                if let value = next(), let parsed = Double(value) { options.sampleSeconds = parsed }
            case "--mode22-seconds":
                if let value = next(), let parsed = Double(value) { options.mode22Seconds = parsed }
            case "--sweep-only":
                options.sweepOnly = true
            case "--service":
                if let value = next(), let parsed = UInt8(value, radix: 16) {
                    options.sweepService = parsed
                }
            case "--skip-ignition":
                options.skipIgnition = true
            case "--scan-seconds":
                if let value = next(), let parsed = Double(value) { options.scanSeconds = parsed }
            case "--ignition-wait":
                if let value = next(), let parsed = Double(value) { options.ignitionWait = parsed }
            case "--device":
                options.device = next()
            case "--out":
                options.outDir = next()
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                if !arg.hasPrefix("-") && options.device == nil {
                    options.device = arg
                }
            }
            index += 1
        }
        return options
    }

    static func printUsage() {
        say("""
        USAGE: OBDProbe [options]

          --device <name>       only connect to an adapter whose name contains this
          --list                scan and print nearby BLE devices, then exit
          --replay <log>        re-analyse a recorded raw_log.ndjson offline
          --scan-seconds <n>    how long each scan window lasts (default 6)
          --scan-timeout <n>    total time to keep retrying the scan (default 90)
          --sample-seconds <n>  live sampling duration (default 20, 0 disables)
          --mode22-seconds <n>  UDS identifier sweep budget (default 150, 0 disables)
          --sweep-only          skip everything except the identifier sweep
          --service <hex>       service to sweep: 22 (default), 21, or 1A
          --ignition-wait <n>   seconds to wait for the ECU after prompting (default 180)
          --skip-ignition       adapter-only probe, no ECU queries
          --out <dir>           results directory (default Probe/results/<timestamp>)
          --self-test           verify the ELM327 parser against captured responses
          -h, --help            this message

        Turn the ignition ON when prompted. The tool polls until the ECU answers.
        """)
    }

    /// Connects to the adapter. Name-based selection is unreliable on these
    /// modules, so if it finds nothing convincing it asks each nearby device for
    /// `ATI` and keeps the one that answers like an ELM327.
    static func acquireAdapter(
        transport: BLETransport,
        logger: SessionLogger,
        options: Options
    ) async throws -> (BLETransport.Candidate, SerialPort) {
        // Explicit name: trust it and fail fast if it is not there.
        if let filter = options.device {
            let candidate = try await transport.findAdapter(
                scanSeconds: options.scanSeconds, nameFilter: filter)
            say("Connecting...")
            return (candidate, try await transport.connect(candidate))
        }

        // Otherwise keep scanning. These adapters stop advertising while connected
        // elsewhere and can take tens of seconds to resume, so a single 6s window
        // is not enough.
        let deadline = Date().addingTimeInterval(options.scanTimeout)
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            do {
                let candidate = try await transport.findAdapter(
                    scanSeconds: options.scanSeconds, nameFilter: nil)
                say("Connecting...")
                let port = try await transport.connect(candidate)
                return (candidate, port)
            } catch {
                let remaining = Int(max(0, deadline.timeIntervalSinceNow))
                say("  attempt \(attempt): not found (\(error)) — \(remaining)s left")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        say("")
        say("No adapter found by name or advertised service.")
        say("If it is plugged in, unplug it and plug it back in: these dongles stop")
        say("advertising while still connected to a phone or a previous session.")
        say("")
        say("Falling back to active identification: connecting to nearby devices")
        say("and asking each one for ATI. A real ELM327 replies 'ELM327 v...'.")
        say("")

        let list = try await transport.scan(seconds: options.scanSeconds)
        let ordered = list.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.rssi > $1.rssi
        }

        for candidate in ordered.prefix(12) {
            let label = candidate.name.isEmpty ? "(unnamed)" : candidate.name
            sayInline("  " + label.padding(toLength: 24, withPad: " ", startingAt: 0)
                      + "rssi=" + String(candidate.rssi) + " ... ")

            do {
                let port = try await transport.connect(candidate)
                let elm = ELMClient(transport: transport, logger: logger)
                let reply = try await elm.send("ATI", timeout: 3)
                let text = reply.statusSummary.uppercased()

                if text.contains("ELM") || text.contains("OBD") || text.contains("SCAN") {
                    say("ELM327 → \(reply.statusSummary)")
                    return (candidate, port)
                }
                say("not an adapter (\(reply.statusSummary))")
                transport.disconnect()
            } catch {
                say("no (\(error))")
                transport.disconnect()
            }
        }

        throw BLEError.noDevice(
            "Tried \(min(12, ordered.count)) nearby devices; none answered ATI as an OBD adapter.")
    }

    // MARK: - Results folder
    static func makeLogger(override: String?) throws -> SessionLogger {
        if let override {
            return try SessionLogger(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.currentDirectoryPath
        let directory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
            .appendingPathComponent(folderStamp(), isDirectory: true)
        return try SessionLogger(directory: directory)
    }

    // MARK: - Parser self-test

    static func runSelfTest() {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String) {
            if condition {
                say("  pass  \(label)")
            } else {
                failures += 1
                say("  FAIL  \(label) — \(detail())")
            }
        }

        say("ELM327 parser self-test")
        say("")

        let atz = ELMClient.parse(command: "ATZ", raw: "\r\rELM327 v1.5\r\r>")
        check("ATZ banner", atz.statusSummary == "ELM327 v1.5", "got \(atz.statusSummary)")

        let at1 = ELMClient.parse(command: "AT@1", raw: "ICSolution\r\r>")
        check("AT@1 vendor", at1.statusSummary == "ICSolution", "got \(at1.statusSummary)")

        let dpn = ELMClient.parse(command: "ATDPN", raw: "6\r\r>")
        check("ATDPN protocol", dpn.statusSummary == "6", "got \(dpn.statusSummary)")

        let bitmap = ELMClient.parse(command: "0100", raw: "\r4100BE1FA813\r\r>")
        check("0100 payload", bitmap.payloadHex == "4100BE1FA813", "got \(bitmap.payloadHex ?? "nil")")
        check("0100 echo stripped", !bitmap.lines.contains { $0.uppercased().contains("0100") },
              "lines: \(bitmap.lines)")

        let echoed = ELMClient.parse(command: "0100", raw: "0100\r4100BE1FA813\r\r>")
        check("echo removed", echoed.payloadHex == "4100BE1FA813", "got \(echoed.payloadHex ?? "nil")")

        let spaced = ELMClient.parse(command: "010C", raw: "41 0C 1A F8\r\r>")
        check("spaces tolerated", spaced.payloadHex == "410C1AF8", "got \(spaced.payloadHex ?? "nil")")

        let noData = ELMClient.parse(command: "0100", raw: "\rNO DATA\r\r>")
        check("NO DATA is not hex", noData.payloadHex == nil, "got \(noData.payloadHex ?? "nil")")
        check("NO DATA flagged", noData.failed, "failed == false")

        let searching = ELMClient.parse(command: "0100", raw: "SEARCHING...\r4100BE1FA813\r\r>")
        check("SEARCHING ignored", searching.payloadHex == "4100BE1FA813",
              "got \(searching.payloadHex ?? "nil")")

        let framed = ELMClient.parse(command: "0902", raw: "014\r0: 49 02 01 4A 4D 46\r1: 58 4C 47 46\r\r>")
        check("multi-frame prefix stripped", framed.payloadHex == "4902014A4D46584C4746",
              "got \(framed.payloadHex ?? "nil")")

        // Regression: this car has two modules answering mode 01. Concatenating
        // their frames fabricated P0043/P0047 and garbled CalID on the first run.
        let dupBitmap = ELMClient.parse(command: "0100", raw: "4100983B8013\r410088180013\r\r>")
        check("duplicate frames kept separate", dupBitmap.payloadFrames.count == 2,
              "got \(dupBitmap.payloadFrames.count)")
        check("first frame wins", dupBitmap.payloadHex == "4100983B8013",
              "got \(dupBitmap.payloadHex ?? "nil")")

        let noCodes = ELMClient.parse(command: "03", raw: "4300\r4300\r\r>")
        let phantom = DTC.list(from: noCodes.dataBytes ?? [])
        check("two empty DTC frames fabricate no codes", phantom.isEmpty, "got \(phantom)")

        let calid = ELMClient.parse(
            command: "0904",
            raw: "013\r0:490401313836\r1:30433937323031\r2:00000000000000\r"
                + "013\r0:490401383633\r1:31423535313042\r2:00000000000000\r\r>")
        check("multi-frame messages split apart", calid.payloadFrames.count == 2,
              "got \(calid.payloadFrames.count)")

        // PID bitmap expansion: BE 1F A8 13 at base 00
        let expanded = Probe.expandBitmap([0xBE, 0x1F, 0xA8, 0x13], base: 0x00)
        check("bitmap expands to 01,03,04,05,06,07,0C,0D,0F,10,11,13,15,1C,1F,20,21",
              expanded.contains(0x0C) && expanded.contains(0x0D) && expanded.contains(0x20) && !expanded.contains(0x02),
              "got \(expanded.map { String(format: "%02X", $0) })")

        // DTC decoding
        check("DTC P0301", DTC.decode([0x03, 0x01]) == "P0301", "got \(DTC.decode([0x03, 0x01]))")
        check("DTC U0100", DTC.decode([0xC1, 0x00]) == "U0100", "got \(DTC.decode([0xC1, 0x00]))")

        say("")
        if failures == 0 {
            say("All parser checks passed.")
        } else {
            say("\(failures) check(s) failed.")
        }
    }
}
