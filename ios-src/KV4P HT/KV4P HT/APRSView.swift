import SwiftUI

// MARK: - APRS Tab

struct APRSView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var selectedEntry: APRSEntry? = nil
    @State private var searchText = ""
    @State private var composeTarget: ComposeTarget?
    @State private var sendAlertReason: String?

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

    // Why compose can't open right now, or nil when it can. The toolbar button
    // stays tappable and shows this instead of silently greying out.
    private var cannotSendReason: String? {
        let connected = store.ble.bleState == .ready
        let hasCallsign = !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
        switch (connected, hasCallsign) {
        case (true, true):   return nil
        case (false, true):  return "Connect a radio to send APRS messages."
        case (true, false):  return "Set your callsign in Settings to send APRS messages."
        case (false, false): return "Connect a radio and set your callsign in Settings to send APRS messages."
        }
    }

    // Empty-state copy: distinguish "nothing heard" from "nothing matches".
    private var emptyState: (title: String, icon: String, detail: String) {
        if !searchText.isEmpty {
            return ("No Results", "magnifyingglass", "No packets match \u{201C}\(searchText)\u{201D}.")
        }
        if store.aprsFilter != "All" && !store.aprs.entries.isEmpty {
            return ("No \(store.aprsFilter.lowercased()) yet", "line.3.horizontal.decrease.circle",
                    "Choose All in the filter menu to see every packet.")
        }
        return ("No APRS packets yet", "antenna.radiowaves.left.and.right", tuneHint)
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
                let empty = emptyState
                ContentUnavailableView {
                    Label {
                        Text(empty.title)
                            .foregroundStyle(t.label2)
                    } icon: {
                        Image(systemName: empty.icon)
                            .foregroundStyle(t.label3)
                    }
                } description: {
                    Text(empty.detail)
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
                    if let reason = cannotSendReason {
                        sendAlertReason = reason
                    } else {
                        composeTarget = ComposeTarget(callsign: "")
                    }
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
            }
        }
        .alert("Can\u{2019}t Send", isPresented: Binding(
            get: { sendAlertReason != nil },
            set: { if !$0 { sendAlertReason = nil } }
        ), presenting: sendAlertReason) { _ in
            Button("OK", role: .cancel) {}
        } message: { reason in
            Text(reason)
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
            // .large too so the form isn't clipped at accessibility text sizes.
            .presentationDetents([.medium, .large])
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

// MARK: - Kind styling (shared by row and detail header)

private extension APRSEntry {
    // Position/object get a teal-ish blend of accent and green so they read as
    // their own category yet stay inside the theme (Night collapses to red).
    func kindColor(_ t: AppTheme) -> Color {
        if isOutgoing { return t.accent }
        switch kind {
        case .message:  return t.accent
        case .bulletin: return t.amber
        case .weather:  return t.green
        default:        return t.accent.mix(with: t.green, by: 0.5)
        }
    }

    var kindIcon: String {
        switch kind {
        case .message:  return isOutgoing ? "arrow.up.message" : "message"
        case .bulletin: return "info.circle"
        case .weather:  return "cloud.sun"
        case .object:   return "mappin.circle"
        default:        return isOutgoing ? "paperplane" : "location"
        }
    }
}

// MARK: - APRS Row

struct APRSRow: View {
    @Environment(\.theme) var t
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 38
    var entry: APRSEntry
    var distanceMi: Double?

    private var kindColor: Color { entry.kindColor(t) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(kindColor.opacity(0.13))
                .frame(width: iconSize, height: iconSize)
                .overlay(
                    Image(systemName: entry.kindIcon)
                        .font(.body.weight(.medium))
                        .foregroundStyle(kindColor)
                )

            // One spacing value between every line so the rhythm is even; the
            // old per-line paddings stacked up under the chip row.
            VStack(alignment: .leading, spacing: 4) {
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
                        .lineSpacing(2)
                        .foregroundStyle(t.label2)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if entry.isOutgoing {
                        Text("Sent")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(t.surface)  // on-accent text; .white breaks Night
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
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        // The chip's own 2pt box padding sits at the bottom edge, so trim 1pt
        // there to balance against the circle's hard top edge.
        .padding(.top, 3)
        .padding(.bottom, 2)
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
                        .fill(entry.kindColor(t).opacity(0.13))
                        .frame(width: headerIconSize, height: headerIconSize)
                        .overlay(
                            Image(systemName: entry.kindIcon)
                                .font(.title2.weight(.medium))
                                .foregroundStyle(entry.kindColor(t))
                        )
                        .accessibilityHidden(true)
                    Text(entry.callsign)
                        .font(.title2.monospaced().bold())
                        .foregroundStyle(t.label)
                    HStack(spacing: 4) {
                        Text("\(entry.isOutgoing ? "Sent" : "Heard") \(entry.time)")
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
                // Kind and time already sit in the section header and station header;
                // only delivery status is new here. VStack so long status lines wrap
                // at large text sizes instead of colliding.
                VStack(alignment: .leading, spacing: 4) {
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
