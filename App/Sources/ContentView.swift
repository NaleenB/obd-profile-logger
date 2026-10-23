import SwiftUI
#if os(macOS)
import AppKit
#endif
import OBDCore

struct ContentView: View {
    @State private var model = LiveModel()
    @State private var showingSessions = false
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        VStack(spacing: 16) {
            header

            if let status = dpfLine {
                Text(status)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }

            if model.signals.isEmpty {
                Text("No standard signals are defined by this vehicle profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.signals) { signal in
                        Tile(signal: signal, value: model.values[signal.pid])
                    }
                }
            }

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

            Spacer(minLength: 0)

            controls
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 540)
        #endif
        .onChange(of: scenePhase) { _, phase in
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("OBDLogger")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                profileMenu
                recordingBadge
            }
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(statusColor)
            if model.isConnected, !model.adapterName.isEmpty {
                Text(model.adapterName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileMenu: some View {
        Menu {
            Button {
                model.selectProfile("auto")
            } label: {
                if model.profileSelection == "auto" {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }

            Divider()

            ForEach(model.availableProfiles) { entry in
                Button {
                    model.selectProfile(entry.id)
                } label: {
                    if entry.id == model.profileSelection {
                        Label(entry.title, systemImage: "checkmark")
                    } else {
                        Text(entry.title)
                    }
                }
            }
        } label: {
            Label(model.profileTitle, systemImage: "car")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusColor: Color {
        if case .failed = model.phase { return .red }
        if case .failed = model.recording { return .red }
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
                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.phase == .connecting)

            }

            HStack(spacing: 12) {
                Button("Sessions") {
                    showingSessions = true
                }
                .buttonStyle(.bordered)

                Button("Prepare export") {
                    model.exportLastSession()
                }
                .buttonStyle(.bordered)
                .disabled(model.lastSessionURL == nil || model.isRecording)

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
    }
}

#Preview {
    ContentView()
}
