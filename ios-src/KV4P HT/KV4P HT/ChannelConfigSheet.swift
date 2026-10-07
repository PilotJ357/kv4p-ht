import SwiftUI

// MARK: - Offset / Tone editor

struct OffsetToneSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @FocusState private var offsetFocused: Bool

    private enum Direction: Int, CaseIterable {
        case minus, simplex, plus
        var label: String {
            switch self {
            case .minus:   return "−"
            case .simplex: return "Simplex"
            case .plus:    return "+"
            }
        }
    }

    @State private var direction: Direction
    @State private var magnitudeText: String
    @State private var toneIndex: Int
    // Index into `presets`, or `presets.count` for a typed-in value.
    @State private var shift: Int

    private static let presets: [Float] = [0.600, 5.000]

    init(store: RadioStore) {
        self.store = store
        // Seed from desired VFO state, not applied — this sheet edits intent.
        let off = store.vfoOffset
        let mag: Float = abs(off) < 0.0005 ? 0.600 : abs(off)
        let text = String(format: "%.3f", mag)
        _direction = State(initialValue: abs(off) < 0.0005 ? .simplex : (off > 0 ? .plus : .minus))
        _magnitudeText = State(initialValue: text)
        _toneIndex = State(initialValue: Int(store.vfoToneIndex))
        _shift = State(initialValue: Self.shift(for: text))
    }

    private static func shift(for text: String) -> Int {
        Float(text).flatMap { presets.firstIndex(of: $0) } ?? presets.count
    }

    private static func toneLabel(_ index: Int) -> String {
        guard let hz = ctcssToneHz(for: UInt8(clamping: index)) else { return "Off" }
        return String(format: "%.1f Hz", hz)
    }

    private var magnitude: Float {
        Float(magnitudeText) ?? 0.600
    }

    private func apply() {
        let offset: Float
        switch direction {
        case .simplex: offset = 0
        case .plus:    offset = magnitude
        case .minus:   offset = -magnitude
        }
        store.setVfoConfig(offset: offset, toneIndex: UInt8(toneIndex))
        dismiss()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $direction) {
                        ForEach(Direction.allCases, id: \.self) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if direction != .simplex {
                        Picker("Shift", selection: $shift) {
                            ForEach(Array(Self.presets.enumerated()), id: \.offset) { i, preset in
                                Text(String(format: "%.3f", preset)).tag(i)
                            }
                            Text("Custom").tag(Self.presets.count)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("Offset", text: $magnitudeText)
                                    .keyboardType(.decimalPad)
                                    .focused($offsetFocused)
                                    .font(.system(.body, design: .monospaced, weight: .semibold))
                                    .foregroundStyle(t.label)
                                    .multilineTextAlignment(.trailing)
                                Text("MHz")
                                    .foregroundStyle(t.label2)
                            }
                        } label: {
                            Text("Offset")
                                .foregroundStyle(t.label)
                        }
                    }
                } header: {
                    Text("TX Offset").foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                Section {
                    Picker(selection: $toneIndex) {
                        Text("Off").tag(0)
                        ForEach(1...CTCSS_TONES.count, id: \.self) { idx in
                            Text(Self.toneLabel(idx)).tag(idx)
                        }
                    } label: {
                        Text("Tone")
                            .foregroundStyle(t.label)
                    } currentValueLabel: {
                        Text(Self.toneLabel(toneIndex))
                            .foregroundStyle(t.label2)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("TX Tone (CTCSS)").foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(t.bg.ignoresSafeArea())
            .navigationTitle("Offset & Tone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    VoiceSheetConfirmButton(title: "Apply", action: apply)
                }
                // The decimal pad has no return key.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { offsetFocused = false }
                }
            }
            // A preset fills the field; "Custom" hands it the keyboard. Skipped when
            // the text already is that preset, so typing "0.6" isn't rewritten mid-entry.
            .onChange(of: shift) { _, s in
                if s < Self.presets.count {
                    if Self.shift(for: magnitudeText) != s {
                        magnitudeText = String(format: "%.3f", Self.presets[s])
                    }
                } else {
                    offsetFocused = true
                }
            }
            // Typing an exact preset value lights its segment.
            .onChange(of: magnitudeText) { _, text in
                let s = Self.shift(for: text)
                if s != shift { shift = s }
            }
        }
    }
}

// MARK: - Confirm button

/// The system confirm (checkmark) button on iOS 26; a bold text button before.
struct VoiceSheetConfirmButton: View {
    @Environment(\.theme) var t
    var title: String
    var action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .confirm, action: action)
                .tint(t.accent)
                .accessibilityLabel(title)
        } else {
            Button(title, action: action)
                .fontWeight(.bold)
                .tint(t.accent)
        }
    }
}
