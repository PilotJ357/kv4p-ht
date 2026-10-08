import SwiftUI

// MARK: - Transcript log
// Saved caption lines (Settings › Save transcripts): browse by day, search,
// copy, delete, and export as plain text.

struct TranscriptLogView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var query = ""
    @State private var confirmClear = false

    private var results: [TranscriptEntry] { store.transcriptLog.search(query) }

    // Newest day first; entries within a day oldest first, like the captions sheet.
    private var days: [(day: Date, entries: [TranscriptEntry])] {
        let cal = Calendar.current
        return Dictionary(grouping: results) { cal.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
        List {
            if !store.saveTranscripts {
                Section {
                    savingOffBanner
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            }
            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.entries) { entry in
                        TranscriptEntryRow(entry: entry, query: query)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = entry.text
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    store.deleteTranscripts(ids: [entry.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteTranscripts(ids: [entry.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(group.day.formatted(date: .complete, time: .omitted))
                        .foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .overlay {
            if results.isEmpty {
                emptyState
                    .allowsHitTesting(false)  // don't cover the Turn On row
            }
        }
        .navigationTitle("Transcript log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search text, channel, or frequency")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: TranscriptLog.exportText(results),
                          subject: Text("Pocket HT transcripts"),
                          preview: SharePreview("Transcripts (\(results.count) lines)")) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(results.isEmpty)
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .disabled(store.transcriptLog.entries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete all saved transcripts?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { store.clearTranscripts() }
        } message: {
            Text("This can't be undone.")
        }
        .environment(\.theme, store.theme)
    }

    private var savingOffBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Saving is off. New captions won't be added to the log.")
                .font(.subheadline)
                .foregroundStyle(t.label2)
            Spacer(minLength: 4)
            Button("Turn On") { store.saveTranscripts = true }
                .glassButtonStyle()
                .controlSize(.small)
                .tint(t.accent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text(query.isEmpty ? "No transcripts yet" : "No matches")
                    .foregroundStyle(t.label2)
            } icon: {
                Image(systemName: query.isEmpty ? "captions.bubble" : "magnifyingglass")
                    .foregroundStyle(t.label3)
            }
        } description: {
            if query.isEmpty {
                Text("Received transmissions captioned with Live captions are saved here while Save transcripts is on. Transcripts stay on this device.")
                    .foregroundStyle(t.label3)
            }
        }
    }
}

private struct TranscriptEntryRow: View {
    @Environment(\.theme) var t
    let entry: TranscriptEntry
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.channelLabel)
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .foregroundStyle(t.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(t.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(t.label3)
            }
            Text(highlighted)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(t.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var highlighted: AttributedString {
        var s = AttributedString(entry.text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return s }
        var searchStart = s.startIndex
        while let r = s[searchStart...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            s[r].backgroundColor = t.accentSoft
            s[r].foregroundColor = t.accent
            searchStart = r.upperBound
        }
        return s
    }
}
