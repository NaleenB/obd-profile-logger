import SwiftUI
import OBDCore

struct SessionsView: View {
    /// The session currently being recorded: never deletable, never exported.
    let activeSessionID: String?
    let onDeleted: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [SessionSummary] = []
    @State private var selected: SessionSummary?
    @State private var exportURL: URL?
    @State private var allExportURL: URL?
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
        NavigationStack {
            VStack(spacing: 0) {
                content
                Divider()
                footer
            }
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            confirmingDeleteAll = true
                        } label: {
                            Label("Delete all", systemImage: "trash")
                        }
                        .disabled(deletableSessions.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .frame(minWidth: 320)
        #if os(macOS)
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if summaries.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "record.circle",
                description: Text("Connect to an adapter and a session starts automatically.")
            )
            .frame(maxHeight: .infinity)
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
                .accessibilityLabel("Delete \(summary.id)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let selected {
                HStack(spacing: 12) {
                    // The identifier is a UTC timestamp; the list above shows
                    // local time. Say which, or the two look contradictory.
                    Text("\(selected.id) · UTC")
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
                }
            } else {
                // Nothing selected: offer the whole set in one click, which is
                // the common case after a drive.
                HStack(spacing: 12) {
                    Text("Select a session to export")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let allExportURL {
                        ShareLink(item: allExportURL) {
                            Label("Share all", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            prepareAll()
                        } label: {
                            Label("Share all", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(deletableSessions.isEmpty)
                    }
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

    private func prepareAll() {
        let exportable = summaries.filter { $0.id != activeSessionID }
        guard !exportable.isEmpty else {
            message = "No finished sessions to share."
            return
        }
        do {
            if let existing = allExportURL { SessionArchive.discard(existing) }
            allExportURL = try SessionArchive.exportAll(exportable.map(\.directory))
            message = nil
        } catch {
            message = "\(error)"
            allExportURL = nil
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
            if let allExportURL { SessionArchive.discard(allExportURL) }
            allExportURL = nil
            onDeleted(removing)
            reload()
            message = nil
        } catch {
            message = "Could not delete: \(error)"
        }
    }
}
