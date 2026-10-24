import SwiftUI
#if os(macOS)
import AppKit
#endif
import OBDCore

struct ContentView: View {
    @State private var model = LiveModel()
    @State private var showingSessions = false
    /// Drives the age of the last reading. It has to be a clock on this side:
    /// when the car stops answering, nothing else on screen changes.
    @State private var now = Date()
    @State private var preparingExport = false
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    if let status = dpfLine {
                        Text(status)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            .opacity(silent ? 0.45 : 1)
                    }

                    if model.signals.isEmpty {
                        Text("No standard signals are defined by this vehicle profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.signals) { signal in
                                Tile(
                                    signal: signal,
                                    value: model.values[signal.pid],
                                    dimmed: silent || model.isStandardStale(signal.pid, now: now)
                                )
                            }
                        }
                    }

                    codesLine

                    if let battery = model.batteryReport, battery.startObserved {
                        batteryLine(battery)
                    }

                    if !model.manufacturerHighlights.isEmpty {
                        manufacturerSection
                    }

                    if let notice = model.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }

            // Outside the scroll view: the one control that has to stay
            // reachable on a small screen.
            controls
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 540)
        #endif
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: scenePhase) { _, phase in
            recordPhase(phase)
            if phase == .active { model.appDidBecomeActive() }
        }
        .sheet(isPresented: $showingSessions) {
            SessionsView(activeSessionID: model.activeSessionID) { deleted in
                model.handleSessionsDeleted(deleted)
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.prepareForTermination()
        }
        #endif
    }

    /// The car has gone quiet. Nothing on screen can change until it answers,
    /// so say why rather than letting the app look frozen.
    private var silent: Bool {
        model.isVehicleSilent(now: now)
    }

    private func recordPhase(_ phase: ScenePhase) {
        switch phase {
        case .active: model.appDidChangePhase(.active)
        case .inactive: model.appDidChangePhase(.inactive)
        case .background: model.appDidChangePhase(.background)
        @unknown default: break
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("OBDLogger")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                if model.isConnected {
                    Text(model.profileCaption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                recordingBadge
            }
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(statusColor)
            if let silence = model.silenceNotice(now: now) {
                Label(silence, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isConnected, !model.adapterName.isEmpty {
                Text(model.adapterName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        if case .failed = model.phase { return .red }
        if case .reconnecting = model.phase { return .orange }
        if case .failed = model.recording { return .red }
        if silent { return .orange }
        return .secondary
    }

    @ViewBuilder
    private var recordingBadge: some View {
        switch model.recording {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .stopped:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Recording error", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    /// Fault codes, with incompleteness stated rather than glossed over: on this
    /// car the DPF has no monitor at all, so "no codes" is not a clean bill.
    @ViewBuilder
    private var codesLine: some View {
        if let diagnostics = model.diagnostics {
            let codes = diagnostics.modules.flatMap(\.allCodes)
            let incomplete = diagnostics.modulesIncomplete

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: incomplete.isEmpty
                      ? (codes.isEmpty ? "checkmark.seal" : "exclamationmark.triangle.fill")
                      : "questionmark.circle")
                Text(codesSummary(diagnostics))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(incomplete.isEmpty ? (codes.isEmpty ? Color.secondary : .red) : .orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func codesSummary(_ diagnostics: VehicleDiagnostics) -> String {
        var parts: [String] = []

        for module in diagnostics.modules {
            let codes = module.allCodes
            if !codes.isEmpty {
                parts.append("\(module.module): " + codes.joined(separator: ", "))
            } else if !module.isComplete {
                parts.append("\(module.module): no answer")
            }
        }

        if parts.isEmpty {
            return diagnostics.isComplete
                ? "No fault codes in \(diagnostics.modules.map(\.module).joined(separator: " or "))"
                : "Code scan incomplete"
        }
        return "Codes — " + parts.joined(separator: " · ")
    }

    private func batteryLine(_ report: BatteryReport) -> some View {
        var parts: [String] = []
        if let crank = report.crankMinimumVolts {
            parts.append(String(format: "crank %.1f V", crank))
        }
        if let running = report.runningVolts {
            parts.append(String(format: "charging %.1f V", running))
        }
        return Text(parts.isEmpty ? "Battery: no start observed" : "Battery: " + parts.joined(separator: " · "))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var manufacturerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Manufacturer data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 8) {
                ForEach(model.manufacturerHighlights) { parameter in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(parameter.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("\(parameter.displayValue) \(parameter.unit ?? "")")
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .opacity(model.isManufacturerStale(parameter, now: now) ? 0.45 : 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var dpfLine: String? {
        guard let dpf = model.dpf else { return nil }
        var parts: [String] = []
        if let soot = dpf.sootByAccumulation {
            parts.append(String(format: "Soot %.2f g/L", soot))
        }
        if let count = dpf.regenerationCount {
            parts.append("\(count) regenerations")
        }
        switch dpf.regenerationMode {
        case .notRequested:
            parts.append("not regenerating")
        case .unknown(let raw):
            parts.append("regen mode \(raw) (unverified)")
        case nil:
            break
        }
        return parts.isEmpty ? nil : "DPF: " + parts.joined(separator: " · ")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(model.isConnected || model.phase == .reconnecting ? "Disconnect" : "Connect") {
                    if model.isConnected || model.phase == .reconnecting {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.phase == .connecting)

            }

            Text(model.versionDescription)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: 12) {
                Button("Sessions") {
                    showingSessions = true
                }
                .buttonStyle(.bordered)

                Button(preparingExport ? "Preparing…" : "Prepare export") {
                    preparingExport = true
                    Task {
                        await model.exportLastSession()
                        preparingExport = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.lastSessionURL == nil || model.isRecording || preparingExport)

                if let url = model.exportURL {
                    ShareLink(item: url) {
                        Label("Share ZIP", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

}

private struct Tile: View {
    let signal: VehicleProfile.StandardSignal
    let value: Double?
    /// Stale values are dimmed rather than removed: knowing what the car last
    /// said is still useful, but it must not look live.
    var dimmed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(signal.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { signal.formatted($0) } ?? "—")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .monospacedDigit()
                Text(signal.unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .opacity(dimmed ? 0.45 : 1)
    }
}

#Preview {
    ContentView()
}
