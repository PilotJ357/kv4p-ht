import SwiftUI

// MARK: - Memories Tab

struct MemoriesView: View {
    @Environment(\.theme) var t
    let store: RadioStore
    @State private var showAddMemory = false
    @State private var editingMemory: Memory? = nil
    @State private var searchText = ""
    @State private var isEditMode = false

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
                        MemoryRow(memory: mem, channelNum: idx + 1, groupColor: t.accent, isActive: mem.id == store.activeMemoryId, isEditMode: isEditMode, onTap: {
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
                    Text("\(group.name) · \(group.items.count)")
                        .foregroundStyle(t.label2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Name, group, or frequency")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(isEditMode ? "Done" : "Edit") {
                    withAnimation { isEditMode.toggle() }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showAddMemory = true } label: {
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
    var memory: Memory
    var channelNum: Int
    var groupColor: Color
    var isActive: Bool
    var isEditMode: Bool = false
    var onTap: () -> Void

    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 24
    @ScaledMetric(relativeTo: .caption2) private var badgeWidth: CGFloat = 38

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Group {
                    if isActive {
                        ZStack {
                            Circle()
                                .fill(groupColor)
                                .frame(width: badgeSize, height: badgeSize)
                            Text("\(channelNum)")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .tracking(0.3)
                                .foregroundStyle(.white)
                        }
                    } else {
                        Text("CH\(channelNum)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(groupColor)
                    }
                }
                .frame(width: badgeWidth)
                .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(memory.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isActive ? groupColor : t.label)
                        if isActive {
                            Text("TUNED")
                                .font(.caption2.weight(.bold))
                                .tracking(0.4)
                                .foregroundStyle(t.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(t.greenSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text(memory.metaString)
                        .font(.footnote)
                        .foregroundStyle(t.label2)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

                Spacer(minLength: 8)

                Text(memory.freqString)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(isActive ? groupColor : t.label2)

                if isEditMode {
                    Image(systemName: "pencil.circle.fill")
                        .font(.body)
                        .foregroundStyle(t.accent)
                        .padding(.leading, 10)
                }
            }
        }
        .listRowBackground(t.surface.overlay(isActive ? groupColor.opacity(0.08) : .clear))
        .listRowSeparatorTint(t.sep)
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
    @State private var freqText = ""
    @State private var offsetText = "0"
    @State private var toneValue: Float = 0
    @State private var scanEnabled = true
    @State private var bandwidth: UInt8 = 0

    init(store: RadioStore, editing: Memory? = nil) {
        self.store = store
        self.editing = editing
        if let m = editing {
            _name = State(initialValue: m.name)
            _group = State(initialValue: m.group)
            _freqText = State(initialValue: m.freqString)
            _offsetText = State(initialValue: m.offset == 0 ? "0" : String(format: "%.3f", m.offset))
            _toneValue = State(initialValue: m.plTone)
            _scanEnabled = State(initialValue: m.scanEnabled)
            _bandwidth = State(initialValue: m.bandwidth)
        }
    }

    private let tones: [Float] = [0, 67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5]

    private func save() {
        guard let freq = Float(freqText), freq > 0 else { return }
        let offset = Float(offsetText) ?? 0
        if var updated = editing {
            updated.name = name
            updated.group = group
            updated.freq = freq
            updated.offset = offset
            updated.plTone = toneValue
            updated.isRepeater = offset != 0
            updated.scanEnabled = scanEnabled
            updated.bandwidth = bandwidth
            store.updateMemory(updated)
        } else {
            store.memories.append(Memory(
                name: name, group: group, freq: freq, offset: offset,
                plTone: toneValue, squelch: 2,
                isRepeater: offset != 0, scanEnabled: scanEnabled,
                bandwidth: bandwidth
            ))
        }
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FieldRow(label: "Name",  value: $name)
                    FieldRow(label: "Group", value: $group)
                } header: {
                    Text("Identity").foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    FieldRow(label: "Frequency", value: $freqText, mono: true)
                    FieldRow(label: "Offset",    value: $offsetText, mono: true)
                    Stepper(
                        onIncrement: {
                            if let idx = tones.firstIndex(of: toneValue), idx < tones.count - 1 { toneValue = tones[idx + 1] }
                        },
                        onDecrement: {
                            if let idx = tones.firstIndex(of: toneValue), idx > 0 { toneValue = tones[idx - 1] }
                        }
                    ) {
                        LabeledContent {
                            Text(toneValue == 0 ? "Off" : String(format: "%.1f Hz", toneValue))
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundStyle(t.label)
                        } label: {
                            Text("Tone (PL)").foregroundStyle(t.label)
                        }
                    }
                } header: {
                    Text("Frequency").foregroundStyle(t.label2)
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
                }
            }
        }
    }
}

private struct FieldRow: View {
    @Environment(\.theme) var t
    var label: String
    @Binding var value: String
    var mono: Bool = false

    var body: some View {
        LabeledContent {
            TextField(label, text: $value, prompt: Text(""))
                .font(mono ? .system(.body, design: .monospaced, weight: .semibold) : .body.weight(.semibold))
                .foregroundStyle(t.label)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(label).foregroundStyle(t.label)
        }
    }
}
