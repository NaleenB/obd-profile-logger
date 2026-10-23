import SwiftUI
import OBDCore

struct ContentView: View {
    @State private var model = LiveModel()
    @State private var showingSessions = false

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

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(LiveSignal.allCases, id: \.self) { signal in
                    Tile(signal: signal, value: model.values[signal])
                }
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
        .frame(minWidth: 380, minHeight: 540)
        .sheet(isPresented: $showingSessions) {
            SessionsView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("OBDLogger")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
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

    private var manufacturerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manufacturer data")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

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

                Button(model.isRecording ? "Stop" : "Record") {
                    model.toggleRecording()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.isConnected || !canRecord)
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

    private var canRecord: Bool {
        if case .failed = model.recording { return false }
        return true
    }
}

private struct Tile: View {
    let signal: LiveSignal
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(signal.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(format: "%.\(signal.fractionDigits)f", $0) } ?? "—")
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
