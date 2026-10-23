import SwiftUI
import OBDCore

struct ContentView: View {
    @State private var model = LiveModel()

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

            Spacer(minLength: 0)

            controls
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OBDLogger")
                .font(.largeTitle.weight(.semibold))
            Text(model.status)
                .font(.subheadline)
                .foregroundStyle(model.phase == .failed("") ? .red : .secondary)
            if model.isConnected, !model.adapterName.isEmpty {
                Text(model.adapterName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Button("Record") {}
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(true)
                .help("Recording arrives with the session recorder")
        }
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
