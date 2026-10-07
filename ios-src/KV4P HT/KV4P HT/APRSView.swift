import SwiftUI

// MARK: - APRS Tab

struct APRSView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var selectedEntry: APRSEntry? = nil
    @State private var searchText = ""
    @State private var composeTarget: ComposeTarget?

    private let filters = ["All", "Messages", "Bulletins", "Positions", "Weather"]

    private var tuneHint: String {
        guard let region = APRSRegion.for(store.aprsBeaconFrequency) else {
            return "Tune to your local APRS frequency to hear traffic"
        }
        return String(format: "Tune to %.3f MHz to hear APRS traffic", region.freq)
    }

    private var filteredEntries: [APRSEntry] {
        var entries: [APRSEntry]
        switch store.aprsFilter {
        case "Messages":  entries = store.aprs.entries.filter { $0.kind == .message }
        case "Bulletins": entries = store.aprs.entries.filter { $0.kind == .bulletin }
        case "Positions": entries = store.aprs.entries.filter { $0.kind == .position || $0.kind == .object }
        case "Weather":   entries = store.aprs.entries.filter { $0.kind == .weather }
        default:          entries = store.aprs.entries
        }
        entries.reverse()  // newest first
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.callsign.lowercased().contains(q) ||
            $0.text.lowercased().contains(q)
        }
    }

    private var canSend: Bool {
        store.ble.bleState == .ready &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let entries = filteredEntries
        List {
            ForEach(entries) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    APRSRow(entry: entry,
                            distanceMi: entry.distanceMi(from: store.locationManager.location))
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No APRS packets yet")
                            .foregroundStyle(t.label2)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(t.label3)
                    }
                } description: {
                    Text(tuneHint)
                        .foregroundStyle(t.label3)
                }
            }
        }
        // Large title like More; the search field sits under it and scrolls away with it.
        .navigationTitle("APRS")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Callsign or message text")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $store.aprsFilter) {
                        ForEach(filters, id: \.self) { f in
                            Text(f).tag(f)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: store.aprsFilter == "All"
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                Button {
                    composeTarget = ComposeTarget(callsign: "")
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .disabled(!canSend)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                APRSDetailView(store: store, entry: entry) { replyTo in
                    selectedEntry = nil
                    composeTarget = ComposeTarget(callsign: replyTo)
                }
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $composeTarget) { target in
            NavigationStack {
                APRSComposeView(store: store, toCallsign: target.callsign)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// Identifiable wrapper so the compose sheet is presented with `.sheet(item:)`,
// giving the view fresh identity per presentation — without this the compose
// view's @State recipient is seeded only once and Reply never pre-fills.
private struct ComposeTarget: Identifiable {
    let id = UUID()
    var callsign: String
}

// MARK: - APRS Row

struct APRSRow: View {
    @Environment(\.theme) var t
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38
    var entry: APRSEntry
    var distanceMi: Double?

    private var kindColor: Color {
        if entry.isOutgoing { return t.accent }
        switch entry.kind {
        case .message:  return t.accent
        case .bulletin: return t.amber
        case .weather:  return t.green
        default:        return t.label2
        }
    }

    private var kindIcon: String {
        switch entry.kind {
        case .message:  return entry.isOutgoing ? "arrow.up.message" : "message"
        case .bulletin: return "info.circle"
        case .weather:  return "cloud.sun"
        case .object:   return "mappin.circle"
        default:        return entry.isOutgoing ? "paperplane" : "location"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(kindColor.opacity(0.13))
                .frame(width: iconSize, height: iconSize)
                .overlay(
                    Image(systemName: kindIcon)
                        .font(.body.weight(.medium))
                        .foregroundStyle(kindColor)
                )
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.isOutgoing && entry.kind == .message ? "→ \(entry.callsign)" : entry.callsign)
                        .font(.subheadline.monospaced().bold())
                        .foregroundStyle(t.label)
                    if entry.isOutgoing && entry.kind == .message {
                        Image(systemName: entry.wasAcknowledged
                              ? "checkmark.circle.fill"
                              : entry.isUndelivered
                              ? "exclamationmark.circle"
                              : entry.heardViaDigi != nil
                              ? "dot.radiowaves.up.forward" : "clock")
                            .font(.caption)
                            .foregroundStyle(entry.wasAcknowledged
                                             ? t.green
                                             : entry.isUndelivered
                                             ? t.red
                                             : entry.heardViaDigi != nil
                                             ? t.accent : t.label3)
                    } else if entry.isOutgoing, entry.heardViaDigi != nil {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.caption)
                            .foregroundStyle(t.accent)
                    }
                    Spacer()
                    Text(entry.time)
                        .font(.caption)
                        .foregroundStyle(t.label2)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.subheadline)
                        .lineSpacing(3)
                        .foregroundStyle(t.label2)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
                HStack(spacing: 8) {
                    if entry.isOutgoing {
                        Text("Sent")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(t.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text(entry.kind.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(kindColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(kindColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let dist = distanceMi {
                        Text(String(format: "%.1f mi", dist))
                            .font(.caption2)
                            .foregroundStyle(t.label3)
                    }
                }
                .padding(.top, 4)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - APRS Detail

struct APRSDetailView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @ScaledMetric(relativeTo: .title2) private var headerIconSize: CGFloat = 60
    @Bindable var store: RadioStore
    var entry: APRSEntry
    var onReply: (String) -> Void

    // Live copy from the store so status/retry state updates after a resend;
    // `entry` is a snapshot captured when the detail was opened.
    private var live: APRSEntry {
        store.aprs.entries.first { $0.id == entry.id } ?? entry
    }

    private var canReply: Bool {
        !entry.isOutgoing &&
        (entry.kind == .message || entry.kind == .bulletin) &&
        store.ble.bleState == .ready &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canResend: Bool {
        live.isOutgoing && live.kind == .message && !live.wasAcknowledged &&
        store.ble.bleState == .ready && !store.isTxOutOfBand
    }

    var body: some View {
        List {
            // Station header
            Section {
                VStack(spacing: 4) {
                    Circle()
                        .fill(t.accent.opacity(0.13))
                        .frame(width: headerIconSize, height: headerIconSize)
                        .overlay(
                            Image(systemName: "message")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(t.accent)
                        )
                    Text(entry.callsign)
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(t.label)
                    HStack(spacing: 4) {
                        Text("Heard \(entry.time)")
                        if let dist = entry.distanceMi(from: store.locationManager.location) {
                            Text("· \(String(format: "%.1f", dist)) mi")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(t.label2)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.kind.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(t.accent)
                        if live.isOutgoing && live.kind == .message {
                            Text(live.wasAcknowledged ? "Acknowledged"
                                 : live.isUndelivered ? "Undelivered"
                                 : "Awaiting ack · retry \(live.retryCount)/\(APRSController.maxRetries)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(live.wasAcknowledged ? t.green
                                                 : live.isUndelivered ? t.red : t.label3)
                        }
                        if entry.isOutgoing, let digi = entry.heardViaDigi {
                            Text("Heard via \(digi)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(t.green)
                        }
                        Spacer()
                        Text(entry.time)
                            .font(.caption)
                            .foregroundStyle(t.label2)
                    }
                    Text(entry.text.isEmpty ? "(no text)" : entry.text)
                        .font(.body)
                        .lineSpacing(3)
                        .foregroundStyle(t.label)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            } header: {
                Text(entry.kind.label)
                    .foregroundStyle(t.label2)
            }

            if let lat = entry.lat, let lon = entry.lon {
                Section {
                    Text(String(format: "%.5f, %.5f", lat, lon))
                        .font(.body.monospaced())
                        .foregroundStyle(t.label)
                        .listRowBackground(t.surface)
                        .listRowSeparatorTint(t.sep)
                } header: {
                    Text("Position")
                        .foregroundStyle(t.label2)
                }
            }

            if canReply || canResend {
                Section {
                    if canReply {
                        Button {
                            onReply(entry.fromCallsign)
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .glassProminentButtonStyle()
                        .controlSize(.large)
                        .tint(t.accent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }

                    if canResend {
                        Button {
                            store.aprs.resendNow(entry.id)
                        } label: {
                            Label(live.isUndelivered ? "Resend (retry expired)" : "Resend now",
                                  systemImage: "arrow.clockwise")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .glassProminentButtonStyle()
                        .controlSize(.large)
                        .tint(live.isUndelivered ? t.red : t.accent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle(entry.callsign)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Compose

struct APRSComposeView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @State var toCallsign: String
    @State private var messageText = ""
    @State private var sendFailed = false

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        store.ble.bleState == .ready && !store.isTxOutOfBand &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("To", text: $toCallsign,
                              prompt: Text("Callsign (optional)").foregroundStyle(t.label3))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(t.label2)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } label: {
                    Text("To")
                        .foregroundStyle(t.label)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)

                LabeledContent {
                    TextField("Message", text: $messageText,
                              prompt: Text("Max 67 characters").foregroundStyle(t.label3))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(t.label2)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } label: {
                    Text("Message")
                        .foregroundStyle(t.label)
                }
                .listRowBackground(t.surface)
                .listRowSeparatorTint(t.sep)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Leave the recipient blank to send a CQ bulletin. Messages are sent on the current frequency.")
                        .foregroundStyle(t.label2)
                    if store.isTxOutOfBand {
                        Text("Current frequency is outside the amateur band — receive only.")
                            .foregroundStyle(t.red)
                    } else if sendFailed {
                        Text("Couldn't send — check connection and callsign.")
                            .foregroundStyle(t.red)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("New Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if store.aprs.sendMessage(to: toCallsign, text: messageText) {
                        dismiss()
                    } else {
                        sendFailed = true
                    }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .tint(t.accent)
                .disabled(!canSend)
            }
        }
    }
}
