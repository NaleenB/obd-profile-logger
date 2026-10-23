import SwiftUI
import OBDCore

struct SessionsView: View {
    /// The session currently being recorded: never deletable.
    let activeSessionID: String?
    /// Receives the IDs that were removed so the caller can drop references.
    let onDeleted: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [SessionSummary] = []
    @State private var selected: SessionSummary?
    @State private var exportURL: URL?
    @State private var message: String?
    @State private var pendingDelete: SessionSummary?
    @State private var confirmingDeleteAll = false

    init(activeSessionID: String? = nil, onDeleted: @escaping (Set<String>) -> Void = { _ in }) {
        self.activeSessionID = activeSessionID
        self.onDeleted = onDeleted
    }

    private var deletableSessions: [SessionSummary] {
        summaries.filter { $0.id != activeSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if summaries.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "record.circle",
                    description: Text("Connect to an adapter and a session starts automatically.")
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
            footer
        }
        #if os(macOS)
        // A comfortable sheet on a desktop window; meaningless on a phone, where
        // it would push the content wider than the screen.
        .frame(minWidth: 480, minHeight: 440)
        #endif
        .onAppear { reload() }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { summary in
            Button("Delete", role: .destructive) { delete(summary) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { summary in
            Text("\(summary.displayTimestamp) — \(summary.sampleCount) samples. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete all saved sessions?",
            isPresented: $confirmingDeleteAll
        ) {
            Button("Delete all", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(deletableSessions.count) session(s). The session currently recording is kept. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Sessions")
                .font(.title2.weight(.semibold))
            Spacer()
            Button(role: .destructive) {
                confirmingDeleteAll = true
            } label: {
                Label("Delete all", systemImage: "trash")
            }
            .disabled(deletableSessions.isEmpty)
            Button("Done") { dismiss() }
        }
        .padding()
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

            if summary.id == activeSessionID {
                Text("recording")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            } else if let adapter = summary.adapterName {
                Text(adapter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if summary.id != activeSessionID {
                Button {
                    pendingDelete = summary
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete this session")
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        VStack(spacing: 6) {
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

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func reload() {
        summaries = SessionStore.summaries()
        if let selected, !summaries.contains(where: { $0.id == selected.id }) {
            self.selected = nil
        }
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

    private func delete(_ summary: SessionSummary) {
        pendingDelete = nil
        do {
            try SessionStore.deleteSession(at: summary.directory)
            if selected?.id == summary.id { selected = nil }
            if let exportURL, exportURL.lastPathComponent.hasPrefix(summary.id) {
                SessionArchive.discard(exportURL)
                self.exportURL = nil
            }
            onDeleted([summary.id])
            reload()
            message = nil
        } catch {
            message = "Could not delete: \(error)"
        }
    }

    private func deleteAll() {
        let removing = Set(deletableSessions.map(\.id))
        do {
            _ = try SessionStore.deleteAllSessions(
                excluding: activeSessionID.map { [$0] } ?? []
            )
            selected = nil
            if let exportURL { SessionArchive.discard(exportURL) }
            exportURL = nil
            onDeleted(removing)
            reload()
            message = nil
        } catch {
            message = "Could not delete: \(error)"
        }
    }
}
