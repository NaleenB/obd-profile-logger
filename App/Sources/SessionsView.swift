import SwiftUI
import OBDCore

struct SessionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [SessionSummary] = []
    @State private var selected: SessionSummary?
    @State private var exportURL: URL?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if summaries.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "record.circle",
                    description: Text("Record a drive and it will appear here.")
                )
            } else {
                List(summaries) { summary in
                    row(summary)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = summary }
                        .listRowBackground(
                            selected?.id == summary.id
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                        )
                }
            }

            Divider()

            HStack(spacing: 12) {
                if let selected {
                    Text(selected.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Prepare ZIP") { prepare(selected) }
                        .buttonStyle(.bordered)
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Select a session to export")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            summaries = SessionStore.summaries()
        }
    }

    private func row(_ summary: SessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: summary.finished ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.finished ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayTimestamp)
                    .font(.body)
                Text(summary.durationDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let adapter = summary.adapterName {
                Text(adapter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func prepare(_ summary: SessionSummary) {
        do {
            if let existing = exportURL { SessionArchive.discard(existing) }
            exportURL = try SessionArchive.export(summary.directory)
            message = nil
        } catch {
            message = "\(error)"
            exportURL = nil
        }
    }
}
