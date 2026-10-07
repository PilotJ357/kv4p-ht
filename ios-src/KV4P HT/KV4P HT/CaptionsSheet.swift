import SwiftUI

// MARK: - Captions sheet

struct CaptionsSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var store: RadioStore

    private var isListening: Bool { store.captionsStatus == .listening }

    var body: some View {
        VStack(spacing: 0) {
            // Mini freq + LIVE badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.currentFreqString)
                        .font(.title.bold().monospacedDigit())
                        .foregroundStyle(t.label)
                    Text("Live transcription · on-device")
                        .font(.footnote)
                        .foregroundStyle(t.label2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(isListening ? t.red : t.label3)
                        .frame(width: 7, height: 7)
                        .shadow(color: isListening ? t.red : .clear, radius: 4)
                    Text(isListening ? "LIVE" : "OFF")
                        .font(.caption.weight(.heavy))
                        .tracking(0.6)
                        .foregroundStyle(isListening ? t.red : t.label2)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(isListening ? t.redSoft : t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Transcript
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.captionLines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(line.callsign)
                                    .font(.system(.caption, design: .monospaced, weight: .bold))
                                    .foregroundStyle(line.active ? t.green : t.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(line.active ? t.greenSoft : t.accentSoft)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if !line.active {
                                    Text(line.time)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(t.label3)
                                } else {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { i in
                                            Circle()
                                                .fill(t.green.opacity(1.0 - Double(i) * 0.35))
                                                .frame(width: 4, height: 4)
                                        }
                                    }
                                }
                            }
                            if line.active {
                                Text(line.text)
                                    .font(.body)
                                    .foregroundStyle(t.label2)
                                    .italic()
                                    .padding(.horizontal, 13)
                            } else {
                                Text(line.text)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .foregroundStyle(t.label)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .background(t.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            if let message = store.captionsStatus.message(language: store.captionLanguage) {
                statusPanel(message)
            } else if store.captionLines.isEmpty {
                Text("Waiting for audio…")
                    .font(.subheadline)
                    .foregroundStyle(t.label3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Captions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TranscriptLogView(store: store)
                } label: {
                    Label("Transcript log", systemImage: "list.bullet.rectangle")
                }
            }
        }
        // Opening captions is the point of intent for the speech prompt.
        .onAppear { store.requestCaptionsPermissionIfNeeded() }
    }

    // Why captions aren't running, plus the one action that fixes it.
    private func statusPanel(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(t.label2)
                .multilineTextAlignment(.center)
            switch store.captionsStatus {
            case .off:
                statusButton("Turn On Live Captions") { store.liveCaptions = true }
            case .needsPermission:
                statusButton("Continue") {
                    store.requestCaptionsPermissionIfNeeded()
                }
            case .denied:
                statusButton("Open Settings") { openURL(CaptionsStatus.appSettingsURL) }
            case .needsNewerOS, .restricted, .unavailable, .listening:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func statusButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .fontWeight(.semibold)
            .glassButtonStyle()
            .controlSize(.large)
            .tint(t.accent)
    }
}
