import SwiftUI

// MARK: - Frequency numpad

struct FreqNumpad: View {
    @Environment(\.theme) var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    var currentFreq: String

    @State private var digits: String
    @State private var hasEdited = false
    @State private var rangeError: String?
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 48
    @ScaledMetric(relativeTo: .title2) private var keyHeight: CGFloat = 52

    private static let maxDigits = 7

    init(store: RadioStore, currentFreq: String) {
        self.store = store
        self.currentFreq = currentFreq
        _digits = State(initialValue: currentFreq.replacingOccurrences(of: ".", with: ""))
    }

    private var displayText: String {
        let padded = digits + String(repeating: "0", count: max(0, 3 - digits.count))
        let mhz = String(padded.prefix(3))
        let khz = String(padded.dropFirst(3).prefix(3))
        return "\(mhz).\(khz)"
    }

    // Any frequency the module tunes (from HELLO) is fine to receive on; TX
    // is band-gated separately by the controller.
    private func commit() {
        guard let f = Float(displayText) else { return }
        let lo = store.radio.minRadioFreq, hi = store.radio.maxRadioFreq
        guard f >= lo && f <= hi else {
            rangeError = String(format: "Out of range: %.3f–%.3f MHz", lo, hi)
            return
        }
        store.sendRadioState(freq: f, ptt: false)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Display
                VStack(spacing: 2) {
                    Text(displayText)
                        .font(.system(size: displaySize, weight: .bold, design: .monospaced))
                        .foregroundStyle(rangeError == nil ? t.label : t.red)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(rangeError ?? "MHz")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(rangeError == nil ? t.label2 : t.red)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 12)

                // The keypad is a custom control, so SET stays under the thumb
                // rather than up in the toolbar.
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        numpadRow(["1","2","3"])
                        numpadRow(["4","5","6"])
                        numpadRow(["7","8","9"])
                        numpadRow([".","0","⌫"])
                    }

                    Button(action: commit) {
                        Text("Set")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
                    .tint(t.accent)
                }
                // Don't stretch edge to edge on iPad or the Duo's inner display.
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .background(t.bg.ignoresSafeArea())
            .navigationTitle("Frequency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                }
            }
        }
    }

    private func numpadRow(_ keys: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button {
                    tap(key)
                } label: {
                    keyLabel(key)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(key == "⌫" ? t.label2 : t.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: keyHeight)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .glassTile(cornerRadius: 12, interactive: true, fallback: t.surface)
                }
                .buttonStyle(.plain)
                // The decimal point is auto-placed, so VoiceOver shouldn't offer a dead key.
                .accessibilityHidden(key == ".")
            }
        }
    }

    @ViewBuilder private func keyLabel(_ key: String) -> some View {
        if key == "⌫" {
            Image(systemName: "delete.left")
                .accessibilityLabel("Delete")
        } else {
            Text(key)
        }
    }

    private func tap(_ key: String) {
        rangeError = nil
        switch key {
        case "⌫":
            guard !digits.isEmpty else { return }
            digits = String(digits.dropLast())
            hasEdited = true
        case ".":
            break  // decimal is auto-placed — key kept for visual familiarity
        default:
            guard digits.count < Self.maxDigits else { return }
            if !hasEdited { digits = ""; hasEdited = true }
            digits.append(key)
        }
    }
}
