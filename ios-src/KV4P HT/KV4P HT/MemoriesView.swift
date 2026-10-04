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
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4, pinnedViews: []) {
                    ForEach(groupedMemories, id: \.name) { group in
                        ListGroupView(header: "\(group.name) · \(group.items.count)") {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, mem in
                                MemoryRow(memory: mem, channelNum: idx + 1, groupColor: t.accent, isLast: idx == group.items.count - 1, isActive: mem.id == store.activeMemoryId, isEditMode: isEditMode, onTap: {
                                    if isEditMode {
                                        editingMemory = mem
                                    } else {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        store.applyMemory(mem)
                                    }
                                })
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
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Name, group, or frequency")
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(isEditMode ? "Done" : "Edit") {
                    withAnimation { isEditMode.toggle() }
                }
                .font(isEditMode ? .system(size: 17, weight: .semibold) : .system(size: 17))
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "plus") { showAddMemory = true }
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
    var isLast: Bool
    var isActive: Bool
    var isEditMode: Bool = false
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if isActive {
                        ZStack {
                            Circle()
                                .fill(groupColor)
                                .frame(width: 24, height: 24)
                            Text("\(channelNum)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(0.3)
                                .foregroundStyle(.white)
                        }
                    } else {
                        Text("CH\(channelNum)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(groupColor)
                    }
                }
                .frame(width: 38)
                .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(memory.name)
                            .font(.system(size: 16.5, weight: .medium))
                            .foregroundStyle(isActive ? groupColor : t.label)
                        if isActive {
                            Text("TUNED")
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(t.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(t.greenSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text(memory.metaString)
                        .font(.system(size: 13))
                        .foregroundStyle(t.label2)
                }

                Spacer(minLength: 8)

                Text(memory.freqString)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? groupColor : t.label2)

                if isEditMode {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(t.accent)
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background(isActive ? groupColor.opacity(0.08) : Color.clear)

            if !isLast {
                Divider()
                    .padding(.leading, 56)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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
            store.updateMemory(updated)
        } else {
            store.memories.append(Memory(
                name: name, group: group, freq: freq, offset: offset,
                plTone: toneValue, squelch: 2,
                isRepeater: offset != 0, scanEnabled: scanEnabled
            ))
        }
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(header: "Identity") {
                        FieldRow(label: "Name",  value: $name)
                        FieldRow(label: "Group", value: $group, isLast: true)
                    }

                    ListGroupView(header: "Frequency") {
                        FieldRow(label: "Frequency", value: $freqText, mono: true)
                        FieldRow(label: "Offset",    value: $offsetText, mono: true)
                        StepperRow(
                            label: "Tone (PL)",
                            valueText: toneValue == 0 ? "Off" : String(format: "%.1f Hz", toneValue),
                            onDecrement: {
                                if let idx = tones.firstIndex(of: toneValue), idx > 0 { toneValue = tones[idx - 1] }
                            },
                            onIncrement: {
                                if let idx = tones.firstIndex(of: toneValue), idx < tones.count - 1 { toneValue = tones[idx + 1] }
                            },
                            isLast: true
                        )
                    }

                    ListGroupView(header: "Scan") {
                        ListRow(
                            title: "Include in Scan",
                            isLast: true,
                            accessory: KVToggle(isOn: $scanEnabled) as (any View)
                        )
                    }
                }
            }
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
    var isLast: Bool = false
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                TextField("", text: $value)
                    .font(mono ? .system(size: 16.5, weight: .semibold, design: .monospaced) : .system(size: 16.5, weight: .semibold))
                    .foregroundStyle(tint ?? t.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}

private struct StepperRow: View {
    @Environment(\.theme) var t
    var label: String
    var valueText: String
    var onDecrement: () -> Void
    var onIncrement: () -> Void
    var isLast: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(valueText)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label)
                    .padding(.trailing, 12)
                HStack(spacing: 0) {
                    Button(action: onDecrement) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(t.label)
                            .frame(width: 40, height: 30)
                    }
                    Divider().frame(height: 30).background(t.sep)
                    Button(action: onIncrement) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(t.label)
                            .frame(width: 40, height: 30)
                    }
                }
                .background(t.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}
