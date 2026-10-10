import SwiftUI
import UniformTypeIdentifiers

// MARK: - Memories Tab

struct MemoriesView: View {
    @Environment(\.theme) var t
    let store: RadioStore
    @State private var showAddMemory = false
    @State private var editingMemory: Memory? = nil
    @State private var searchText = ""
    @State private var isEditMode = false
    @State private var showImporter = false
    @State private var pendingImport: RepeaterImport? = nil
    @State private var importError: String? = nil

    private var filteredMemories: [Memory] {
        guard !searchText.isEmpty else { return store.memories }
        let q = searchText.lowercased()
        return store.memories.filter {
            $0.name.lowercased().contains(q) ||
            $0.group.lowercased().contains(q) ||
            $0.freqString.contains(q) ||
            $0.notes.lowercased().contains(q)
        }
    }

    private var groupedMemories: [(name: String, items: [Memory])] {
        let groups = Dictionary(grouping: filteredMemories, by: \.group)
        return groups.sorted { $0.key < $1.key }.map { (name: $0.key, items: $0.value) }
    }

    var body: some View {
        List {
            ForEach(groupedMemories, id: \.name) { group in
                Section {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, mem in
                        MemoryRow(memory: mem, channelNum: idx + 1, isActive: mem.id == store.activeMemoryId, isEditMode: isEditMode, onTap: {
                            if isEditMode {
                                editingMemory = mem
                            } else {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                store.applyMemory(mem)
                            }
                        })
                        // This radio's module can't tune it (e.g. VHF memory on UHF).
                        .opacity(store.isTunable(mem) ? 1 : 0.4)
                        .swipeActions(edge: .leading) {
                            Button {
                                editingMemory = mem
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(t.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteMemory(id: mem.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                editingMemory = mem
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.deleteMemory(id: mem.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(group.name)
                        .foregroundStyle(t.label2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .overlay {
            if groupedMemories.isEmpty {
                let searching = !searchText.isEmpty
                ContentUnavailableView {
                    Label {
                        Text(searching ? "No Results" : "No memories yet")
                            .foregroundStyle(t.label2)
                    } icon: {
                        Image(systemName: searching ? "magnifyingglass" : "star")
                            .foregroundStyle(t.label3)
                    }
                } description: {
                    Text(searching ? "No memories match \u{201C}\(searchText)\u{201D}."
                                   : "Tap + to save a frequency or import a repeater CSV.")
                        .foregroundStyle(t.label3)
                }
            }
        }
        // Large title like More; the search field sits under it and scrolls away with it.
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Name, group, or frequency")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(isEditMode ? "Done" : "Edit") {
                    withAnimation { isEditMode.toggle() }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { showAddMemory = true } label: {
                        Label("New Memory", systemImage: "square.and.pencil")
                    }
                    Button { showImporter = true } label: {
                        Label("Import Repeaters (CSV)…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Add Memory", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddMemory) {
            AddMemoryView(store: store)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // RepeaterBook / CHIRP exports the user downloaded themselves; no network.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            do {
                pendingImport = try RepeaterImport.load(result.get())
            } catch {
                importError = error.localizedDescription
            }
        }
        .sheet(item: $pendingImport) { file in
            RepeaterImportView(store: store, file: file)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Couldn't Import", isPresented: Binding(get: { importError != nil },
                                                      set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $editingMemory) { mem in
            AddMemoryView(store: store, editing: mem)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Memory row

struct MemoryRow: View {
    @Environment(\.theme) var t
    @Environment(\.dynamicTypeSize) private var typeSize
    var memory: Memory
    var channelNum: Int
    var isActive: Bool
    var isEditMode: Bool = false
    var onTap: () -> Void

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 30

    // Same circle in both states so rows don't change shape when tuned:
    // soft fill + accent number, or solid accent + on-accent number.
    private var badge: some View {
        Text("\(channelNum)")
            .font(.footnote.bold().monospacedDigit())
            .foregroundStyle(isActive ? t.surface : t.accent)
            .frame(width: badgeSize, height: badgeSize)
            .background(isActive ? t.accent : t.accentSoft, in: Circle())
            .accessibilityLabel("Channel \(channelNum)")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(memory.name)
                .font(.body.weight(.medium))
                .foregroundStyle(t.label)
            Text(memory.metaString)
                .font(.footnote)
                .foregroundStyle(t.label2)
        }
    }

    private var frequency: some View {
        Text(memory.freqString)
            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
            .foregroundStyle(t.label2)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                badge

                // Accessibility sizes: the frequency drops under the name instead of
                // squeezing it into a one-word-per-line column.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        details
                        frequency
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                } else {
                    details
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 8)
                    frequency
                }

                if isEditMode {
                    Image(systemName: "pencil.circle.fill")
                        .font(.body)
                        .foregroundStyle(t.accent)
                }
            }
        }
        // Tuned = soft row tint + solid badge; nothing else changes color.
        .listRowBackground(t.surface.overlay(isActive ? t.accentSoft : .clear))
        .listRowSeparatorTint(t.sep)
        .accessibilityValue(isActive ? "Tuned" : "")
    }
}

// MARK: - Add Memory sheet

struct AddMemoryView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    let store: RadioStore
    let editing: Memory?

    @State private var name = ""
    @State private var group = ""
    @State private var notes = ""
    @State private var freqText = ""
    @State private var offsetText = "0"
    @State private var toneValue: Float = 0
    @State private var rxToneValue: Float = 0
    @State private var scanEnabled = true
    @State private var bandwidth: UInt8 = 0

    init(store: RadioStore, editing: Memory? = nil) {
        self.store = store
        self.editing = editing
        if let m = editing {
            _name = State(initialValue: m.name)
            _group = State(initialValue: m.group)
            _notes = State(initialValue: m.notes)
            _freqText = State(initialValue: m.freqString)
            _offsetText = State(initialValue: m.offset == 0 ? "0" : String(format: "%.3f", m.offset))
            _toneValue = State(initialValue: m.plTone)
            _rxToneValue = State(initialValue: m.rxTone)
            _scanEnabled = State(initialValue: m.scanEnabled)
            _bandwidth = State(initialValue: m.bandwidth)
        }
    }

    private let tones: [Float] = [0] + CTCSS_TONES

    // Save is disabled until this parses, rather than silently doing nothing.
    private var isValid: Bool { (Float(freqText) ?? 0) > 0 }

    private func save() {
        guard let freq = Float(freqText), freq > 0 else { return }
        let offset = Float(offsetText) ?? 0
        if var updated = editing {
            updated.name = name
            updated.group = group
            updated.notes = notes
            updated.freq = freq
            updated.offset = offset
            updated.plTone = toneValue
            updated.rxTone = rxToneValue
            updated.isRepeater = offset != 0
            updated.scanEnabled = scanEnabled
            updated.bandwidth = bandwidth
            store.updateMemory(updated)
        } else {
            store.memories.append(Memory(
                name: name, group: group, freq: freq, offset: offset,
                plTone: toneValue, rxTone: rxToneValue, squelch: 2,
                isRepeater: offset != 0, notes: notes, scanEnabled: scanEnabled,
                bandwidth: bandwidth
            ))
        }
        dismiss()
    }

    private func toneStepper(_ label: String, value: Binding<Float>) -> some View {
        Stepper(
            onIncrement: {
                if let idx = tones.firstIndex(of: value.wrappedValue), idx < tones.count - 1 { value.wrappedValue = tones[idx + 1] }
            },
            onDecrement: {
                if let idx = tones.firstIndex(of: value.wrappedValue), idx > 0 { value.wrappedValue = tones[idx - 1] }
            }
        ) {
            LabeledContent {
                Text(value.wrappedValue == 0 ? "Off" : String(format: "%.1f Hz", value.wrappedValue))
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundStyle(t.label)
            } label: {
                Text(label).foregroundStyle(t.label)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow(label: "Name",  value: $name)
                    FieldRow(label: "Group", value: $group)
                    FieldRow(label: "Notes", value: $notes)
                } header: {
                    Text("Identity").foregroundStyle(t.label2)
                } footer: {
                    Text("Notes show under the channel name on the Voice screen.")
                        .foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    FieldRow(label: "Frequency", value: $freqText, mono: true, keyboard: .decimalPad)
                    // numbersAndPunctuation, not decimalPad: offsets can be negative.
                    FieldRow(label: "Offset",    value: $offsetText, mono: true, keyboard: .numbersAndPunctuation)
                    toneStepper("TX Tone", value: $toneValue)
                    toneStepper("RX Tone", value: $rxToneValue)
                } header: {
                    Text("Frequency").foregroundStyle(t.label2)
                } footer: {
                    Text("In MHz. Offset is signed (for example -0.600); 0 means simplex. RX Tone mutes receive unless the signal carries it.")
                        .foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    Picker(selection: $bandwidth) {
                        Text("Wide").tag(UInt8(0))
                        Text("Narrow").tag(UInt8(1))
                    } label: {
                        Text("Bandwidth").foregroundStyle(t.label)
                    }
                    .tint(t.label2)
                } header: {
                    Text("Transmit").foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    Toggle(isOn: $scanEnabled) {
                        Text("Include in Scan").foregroundStyle(t.label)
                    }
                    .tint(t.green)
                } header: {
                    Text("Scan").foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            }
            .scrollContentBackground(.hidden)
            .background(t.bg.ignoresSafeArea())
            .navigationTitle(editing == nil ? "New Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.bold)
                        .disabled(!isValid)
                }
            }
        }
    }
}

struct FieldRow: View {
    @Environment(\.theme) var t
    var label: String
    @Binding var value: String
    var mono: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        LabeledContent {
            TextField(label, text: $value, prompt: Text(""))
                .font(mono ? .system(.body, design: .monospaced, weight: .semibold) : .body.weight(.semibold))
                .foregroundStyle(t.label)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
        } label: {
            Text(label).foregroundStyle(t.label)
        }
    }
}
