import SwiftUI

// MARK: - Transcript log
// Saved caption lines (Settings › Save transcripts): browse by day, search,
// copy, delete, and export as plain text.

struct TranscriptLogView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    // Sheet root shows a custom back to this tab; nil when pushed, so the
    // system back button is used instead.
    var backLabel: String? = nil
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                if !store.saveTranscripts {
                    savingOffBanner
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
                        }
                    } header: {
                        Text(group.day.formatted(date: .complete, time: .omitted).uppercased())
                            .font(.system(size: 12.5, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(t.label2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .background(t.bg)
                    }
                }
                if results.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Transcript log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search text, channel, or frequency")
        .toolbar {
            if let backLabel {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text(backLabel)
                                .font(.system(size: 17))
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: TranscriptLog.exportText(results),
                          subject: Text("Pocket HT transcripts"),
                          preview: SharePreview("Transcripts (\(results.count) lines)")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(results.isEmpty)
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .disabled(store.transcriptLog.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
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
        HStack(alignment: .center, spacing: 10) {
            Text("Saving is off. New captions won't be added to the log.")
                .font(.system(size: 14))
                .foregroundStyle(t.label2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Turn On") { store.saveTranscripts = true }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(t.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "captions.bubble" : "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(t.label3)
            Text(query.isEmpty ? "No transcripts yet" : "No matches")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(t.label)
            if query.isEmpty {
                Text("Received transmissions captioned with Live captions are saved here while Save transcripts is on. Transcripts stay on this device.")
                    .font(.system(size: 14))
                    .foregroundStyle(t.label2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 48)
    }
}

private struct TranscriptEntryRow: View {
    @Environment(\.theme) var t
    let entry: TranscriptEntry
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.channelLabel)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(t.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(t.label3)
            }
            Text(highlighted)
                .font(.system(size: 16.5))
                .lineSpacing(4)
                .foregroundStyle(t.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
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
