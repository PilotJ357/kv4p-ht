import SwiftUI

// MARK: - Repeater CSV import

/// A parsed file waiting for the user to name a group and save.
struct RepeaterImport: Identifiable {
    let id = UUID()
    var fileName: String
    var parsed: RepeaterCSV.Parsed

    /// Reads a file the user picked in the document picker. No network: the
    /// user brings their own RepeaterBook or CHIRP export.
    static func load(_ url: URL) throws -> RepeaterImport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return RepeaterImport(fileName: url.deletingPathExtension().lastPathComponent,
                              parsed: try RepeaterCSV.parse(data))
    }
}

struct RepeaterImportView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    let store: RadioStore
    let file: RepeaterImport

    @State private var group: String
    @State private var includeUntunable = false

    static let repeaterBookURL = URL(string: "https://www.repeaterbook.com")!

    init(store: RadioStore, file: RepeaterImport) {
        self.store = store
        self.file = file
        _group = State(initialValue: file.fileName)
    }

    private var rows: [(id: Int, memory: Memory, tunable: Bool)] {
        file.parsed.entries.enumerated().map { idx, entry in
            let mem = entry.memory(group: "")
            return (idx, mem, store.isTunable(mem))
        }
    }

    private var trimmedGroup: String { group.trimmingCharacters(in: .whitespaces) }

    private func save(_ rows: [(id: Int, memory: Memory, tunable: Bool)]) {
        let group = trimmedGroup
        let picked = rows.filter { includeUntunable || $0.tunable }.map {
            var mem = $0.memory
            mem.group = group
            return mem
        }
        store.memories.append(contentsOf: picked)  // one didSet, one save
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    var body: some View {
        let rows = rows
        let untunable = rows.filter { !$0.tunable }.count
        let saveCount = includeUntunable ? rows.count : rows.count - untunable

        NavigationStack {
            Form {
                Section {
                    FieldRow(label: "Group", value: $group)
                    if untunable > 0 {
                        Toggle(isOn: $includeUntunable) {
                            Text("Include out-of-range").foregroundStyle(t.label)
                        }
                        .tint(t.green)
                    }
                } header: {
                    Text("Save to").foregroundStyle(t.label2)
                } footer: {
                    let note = footer(untunable: untunable)
                    if !note.isEmpty {
                        Text(note).foregroundStyle(t.label2)
                    }
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    ForEach(rows, id: \.id) { row in
                        ImportRow(memory: row.memory, tunable: row.tunable)
                            .opacity(row.tunable || includeUntunable ? 1 : 0.4)
                    }
                } header: {
                    Text("\(rows.count) from \(file.parsed.format.label)")
                        .foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                if file.parsed.format.isRepeaterBook {
                    Section {
                        Link(destination: Self.repeaterBookURL) {
                            ExternalLinkLabel(title: "Data courtesy of RepeaterBook.com")
                        }
                    }
                    .listRowBackground(t.surface)
                    .listRowSeparatorTint(t.sep)
                }
            }
            .scrollContentBackground(.hidden)
            .background(t.bg.ignoresSafeArea())
            .navigationTitle("Import Repeaters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(rows) }
                        .fontWeight(.bold)
                        .disabled(trimmedGroup.isEmpty || saveCount == 0)
                }
            }
        }
    }

    private func footer(untunable: Int) -> String {
        var parts: [String] = []
        if untunable > 0 {
            let range = String(format: "%.0f–%.0f MHz", store.radio.minRadioFreq, store.radio.maxRadioFreq)
            parts.append("\(untunable) can't be tuned by this radio's \(range) module"
                         + (includeUntunable ? " but will be saved." : " and will be skipped."))
        }
        if file.parsed.skipped > 0 {
            let n = file.parsed.skipped
            parts.append(n == 1 ? "1 row without a frequency was ignored." : "\(n) rows without a frequency were ignored.")
        }
        return parts.joined(separator: " ")
    }
}

private struct ImportRow: View {
    @Environment(\.theme) var t
    var memory: Memory
    var tunable: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(memory.name.isEmpty ? memory.freqString : memory.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(t.label)
                Text(tunable ? memory.metaString : "Out of range · \(memory.metaString)")
                    .font(.footnote)
                    .foregroundStyle(t.label2)
            }
            Spacer(minLength: 8)
            Text(memory.freqString)
                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                .foregroundStyle(t.label2)
        }
        .accessibilityElement(children: .combine)
    }
}
