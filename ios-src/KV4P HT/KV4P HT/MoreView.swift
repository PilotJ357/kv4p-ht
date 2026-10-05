import SwiftUI
import UserNotifications

// MARK: - More Tab

struct MoreView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showSettings = false
    @State private var showDeviceInfo = false
    @State private var showPosition = false
    @State private var showPrivacy = false
    @State private var showAbout = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Radio rows
                    ListGroupView {
                        Button { showDeviceInfo = true } label: {
                            ListRow(
                                title: "Device & firmware",
                                value: store.ble.hello.map { "v\($0.firmwareVersion)" } ?? "–",
                                leading: IconTile(color: t.accent, systemImage: "antenna.radiowaves.left.and.right") as (any View),
                                isLast: false
                            )
                        }
                        .buttonStyle(.plain)
                        Button { showPosition = true } label: {
                            ListRow(
                                title: "My position & beacon",
                                value: store.aprsBeaconEnabled ? "On" : "Off",
                                leading: IconTile(color: t.green, systemImage: "location.fill") as (any View),
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Settings / Privacy rows
                    ListGroupView {
                        Button { showSettings = true } label: {
                            ListRow(
                                title: "Settings",
                                leading: IconTile(color: Color(hex: "8E8E93"), systemImage: "gearshape.fill") as (any View),
                                isLast: false
                            )
                        }
                        .buttonStyle(.plain)
                        Button { showPrivacy = true } label: {
                            ListRow(
                                title: "Privacy",
                                leading: IconTile(color: t.green, systemImage: "hand.raised.fill") as (any View),
                                isLast: false
                            )
                        }
                        .buttonStyle(.plain)
                        Button { showAbout = true } label: {
                            ListRow(
                                title: "About",
                                leading: IconTile(color: t.accent, systemImage: "info.circle.fill") as (any View),
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Pocket HT · For KV4P BLE radios · GPLv3")
                        .font(.system(size: 12.5))
                        .foregroundStyle(t.label3)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                        .padding(.bottom, 16)
                }
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDeviceInfo) {
            NavigationStack {
                DeviceInfoView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPosition) {
            NavigationStack {
                BeaconSettingsView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                AboutView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                PrivacyPolicyView()
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    var backLabel = "More"  // tab the sheet was opened from
    @State private var showAprsSquelchInfo = false
    @State private var captionsAlert: CaptionsStatus? = nil
    @Environment(\.openURL) private var openURL

    private let aprsFrequencies = ["Current", "144.3900", "144.5750", "144.6400", "144.6600", "144.8000", "145.1750", "145.8250"]
    private let aprsFrequencyLabels = [
        "Current",
        "144.3900 (Americas)",
        "144.5750 (New Zealand)",
        "144.6400 (Japan)",
        "144.6600 (Australia)",
        "144.8000 (Europe/Africa)",
        "145.1750 (Australia, alt)",
        "145.8250 (ISS/satellite)",
    ]

    private var captionsFooter: String {
        let onDevice = "On-device speech recognition. No data sent to the cloud."
        switch store.captionsStatus {
        case .denied, .restricted, .unavailable:
            return store.captionsStatus.message(language: store.captionLanguage) ?? onDevice
        case .off, .needsPermission, .listening:
            return onDevice
        }
    }

    private func openAppSettings() {
        openURL(CaptionsStatus.appSettingsURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    // APRS
                    ListGroupView(header: "APRS") {
                        TextFieldRow(title: "Callsign",  text: $store.callsign,  placeholder: "N0CALL", isLast: false)
                        TextFieldRow(title: "APRS SSID", text: $store.aprsSSID,  placeholder: "Optional", isLast: false, autocap: .never)
                        PickerRow(title: "APRS frequency",
                                  selection: $store.aprsBeaconFrequency,
                                  options: aprsFrequencies,
                                  labels: aprsFrequencyLabels,
                                  isLast: false)
                        HStack(spacing: 0) {
                            ListRow(title: "Silence audio on APRS freq", isLast: true, dense: true,
                                    accessory: KVToggle(isOn: $store.silenceRxOnAprsFreq) as (any View))
                            Button { showAprsSquelchInfo = true } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(t.accent)
                            }
                            .padding(.trailing, 16)
                            .popover(isPresented: $showAprsSquelchInfo) {
                                Text("APRS packets are decoded regardless of squelch. Enable this to mute RX audio while tuned to your APRS frequency so you don't hear packet noise.")
                                    .font(.system(size: 14))
                                    .padding()
                                    .frame(width: 280)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .presentationCompactAdaptation(.popover)
                            }
                        }
                    }

                    // Notifications
                    ListGroupView(header: "Notifications") {
                        NavigationLink {
                            APRSNotificationsView(store: store)
                        } label: {
                            ListRow(title: "APRS notifications",
                                    value: store.aprsNotify.enabled ? "On" : "Off",
                                    isLast: true)
                        }
                        .buttonStyle(.plain)
                    }

                    // Radio
                    ListGroupView(header: "Radio") {
                        SquelchSliderRow(store: store)
                        Divider().padding(.leading, 16).background(t.sep)
                        TXPowerRow(store: store)
                        Divider().padding(.leading, 16).background(t.sep)
                        ListRow(title: "Band",
                                value: store.ble.hello.map { $0.rfModuleType == 0 ? "VHF" : "UHF" } ?? "–",
                                showChevron: false, isLast: true)
                    }

                    // Audio filters
                    ListGroupView(
                        header: "Audio filters",
                        footer: "Controlled by firmware."
                    ) {
                        ListRow(title: "High-pass", isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.filterHighPass) as (any View))
                        ListRow(title: "Low-pass",  isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.filterLowPass) as (any View))
                        BandwidthRow(store: store)
                    }

                    // Transcription
                    ListGroupView(
                        header: "Transcription",
                        footer: captionsFooter
                    ) {
                        ListRow(title: "Live captions",
                                isLast: !store.captionsStatus.opensSettings, dense: true,
                                accessory: KVToggle(isOn: $store.liveCaptions) as (any View))
                        if store.captionsStatus.opensSettings {
                            Button(action: openAppSettings) {
                                ListRow(title: "Allow in Settings", isLast: true, dense: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Turning captions on asks for speech permission (in
                    // RadioStore); if it can't work, say why right away.
                    .onChange(of: store.liveCaptions) { _, enabled in
                        guard enabled else { return }
                        switch store.captionsStatus {
                        case .denied, .restricted, .unavailable:
                            captionsAlert = store.captionsStatus
                        default:
                            break
                        }
                    }
                    .alert("Captions unavailable",
                           isPresented: Binding(get: { captionsAlert != nil },
                                                set: { if !$0 { captionsAlert = nil } }),
                           presenting: captionsAlert) { status in
                        if status.opensSettings {
                            Button("Open Settings", action: openAppSettings)
                            Button("Not Now", role: .cancel) {}
                        } else {
                            Button("OK", role: .cancel) {}
                        }
                    } message: { status in
                        Text(status.message(language: store.captionLanguage) ?? "")
                    }

                    // Appearance
                    ListGroupView(header: "Appearance") {
                        VStack(spacing: 0) {
                            Divider().opacity(0)
                            Picker("Appearance", selection: $store.themeMode) {
                                ForEach(AppThemeMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            Divider().padding(.leading, 16).background(t.sep)
                        }
                        ListRow(title: "Sticky PTT",     dense: true,
                                accessory: KVToggle(isOn: $store.stickyPTT) as (any View))
                        TxTimeoutRow(store: store)
                    }
                }
                .padding(.bottom, 32)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
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
        .environment(\.theme, store.theme)
    }
}

// MARK: - TX power picker

private struct TXPowerRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private let options = ["Low", "High"]

    var body: some View {
        HStack {
            Text("TX power")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(t.label)
            Spacer()
            Picker("TX power", selection: $store.txPower) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
            .disabled(!store.radio.hasHighLowPowerSwitch)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

// MARK: - TX time-out picker

private struct TxTimeoutRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        HStack {
            Text("TX time-out")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(t.label)
            Spacer()
            Picker("TX time-out", selection: $store.txTimeoutSeconds) {
                ForEach(TxTimeout.options, id: \.self) { secs in
                    Text(TxTimeout.label(secs)).tag(secs)
                }
            }
            .pickerStyle(.menu)
            .tint(t.label2)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

// MARK: - Bandwidth picker

private struct BandwidthRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var bwBinding: Binding<String> {
        Binding(
            get: { store.bandwidth == 0 ? "Wide" : "Narrow" },
            set: { store.bandwidth = $0 == "Wide" ? 0 : 1 }
        )
    }

    var body: some View {
        HStack {
            Text("Bandwidth")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(t.label)
            Spacer()
            Picker("Bandwidth", selection: bwBinding) {
                Text("Wide").tag("Wide")
                Text("Narrow").tag("Narrow")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

// MARK: - Squelch slider

private struct SquelchSliderRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var squelchPct: Double { Double(store.squelch) / 9.0 }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Squelch")
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text("Level \(store.squelch)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.accent).frame(width: geo.size.width * squelchPct, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: geo.size.width * squelchPct - 9.5)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let pct = max(0, min(1, v.location.x / geo.size.width))
                            store.squelch = UInt8(round(pct * 9.0))
                        }
                        .onEnded { _ in
                            store.radio.setSquelch(store.squelch)
                        }
                )
            }
            .frame(height: 19)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Device Info stub

struct DeviceInfoView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    if let hello = store.ble.hello {
                        ListGroupView(header: "Hello Frame") {
                            DeviceDetailRow(label: "Firmware", value: "v\(hello.firmwareVersion)", isLast: false)
                            DeviceDetailRow(label: "Radio Module", value: hello.radioModuleFound ? "Found" : "Not found", isLast: false)
                            DeviceDetailRow(label: "RF Module", value: hello.rfModuleType == 0 ? "VHF" : "UHF", isLast: false)
                            DeviceDetailRow(label: "Freq Range", value: "\(String(format: "%.1f", hello.minFreq))–\(String(format: "%.1f", hello.maxFreq)) MHz", isLast: false)
                            DeviceDetailRow(label: "Features", value: "0x\(String(hello.features, radix: 16))", isLast: true)
                        }
                    } else {
                        ListGroupView(header: "Hello Frame") {
                            Text("No device connected")
                                .font(.system(size: 15))
                                .foregroundStyle(t.label2)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Device & Firmware")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .environment(\.theme, store.theme)
    }
}

// MARK: - Beacon settings

struct BeaconSettingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @State private var beaconStatus: String? = nil
    @State private var consentAction: ConsentAction? = nil

    // What to do once the user accepts the public-broadcast disclosure.
    private enum ConsentAction { case enableBeacon, beaconNow }

    static let consentMessage = "Position beacons transmit your callsign and location over the air on APRS. Anyone listening can receive them, and internet gateways (iGates) relay them to public websites such as aprs.fi, where they are archived and can't be deleted.\n\nBeacons are sent at the chosen interval while the radio is connected, including when the app is in the background. Turn on Approximate position to round your location to about 1 km."

    // Curated APRS symbols (table "/"), mirroring Android's APRSIconType subset.
    private static let symbols: [(code: String, label: String)] = [
        ("[", "Person"), ("-", "House"), (">", "Car"), ("b", "Bicycle"),
        ("v", "Van"), ("k", "Truck"), ("Y", "Sailboat"), ("$", "Phone"),
    ]

    private let intervals = [5, 10, 15, 30, 60]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(
                        header: "Position beacon",
                        footer: "Off by default. When on, publicly broadcasts your callsign and GPS position over APRS at the chosen interval while the radio is connected, including in the background. Requires a callsign and APRS frequency configured in Settings."
                    ) {
                        ListRow(title: "Beacon position", isLast: false, dense: true,
                                accessory: KVToggle(isOn: beaconEnabledBinding) as (any View))
                        PickerRow(title: "Interval",
                                  selection: Binding(
                                      get: { "\(store.aprsBeaconIntervalMin) min" },
                                      set: { store.aprsBeaconIntervalMin = Int($0.dropLast(4)) ?? 15 }),
                                  options: intervals.map { "\($0) min" },
                                  isLast: false)
                        ListRow(title: "Approximate position", isLast: true, dense: true,
                                accessory: KVToggle(isOn: $store.aprsPositionApprox) as (any View))
                    }

                    if store.locationManager.access.isUnavailable {
                        LocationUnavailableNotice(
                            access: store.locationManager.access,
                            consequence: "Position beacons can't be sent until it's available.")
                    }

                    ListGroupView(header: "Map symbol") {
                        PickerRow(title: "Symbol",
                                  selection: Binding(
                                      get: {
                                          Self.symbols.first { $0.code == store.aprsSymbol }?.label
                                              ?? Self.symbols[0].label
                                      },
                                      set: { label in
                                          store.aprsSymbol = Self.symbols.first { $0.label == label }?.code ?? "["
                                      }),
                                  options: Self.symbols.map(\.label),
                                  isLast: true)
                    }

                    Button {
                        if store.aprsBeaconConsented {
                            sendBeaconNow()
                        } else {
                            consentAction = .beaconNow
                        }
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Beacon now")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(t.green)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if let status = beaconStatus {
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(t.label2)
                            .padding(.top, 4)
                    }

                    if store.aprsBeaconConsented {
                        Button("Stop sharing my position") {
                            store.aprsBeaconConsented = false
                            beaconStatus = nil
                        }
                        .font(.system(size: 15))
                        .foregroundStyle(t.red)
                        .padding(.top, 16)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Position & Beacon")
        .navigationBarTitleDisplayMode(.large)
        // A "Not sent" reason is stale once location access changes.
        .onChange(of: store.locationManager.access) { beaconStatus = nil }
        .alert("Share your position publicly?",
               isPresented: Binding(get: { consentAction != nil },
                                    set: { if !$0 { consentAction = nil } }),
               presenting: consentAction) { action in
            Button("Share Position") {
                store.aprsBeaconConsented = true
                switch action {
                case .enableBeacon:
                    store.aprsBeaconEnabled = true
                    store.locationManager.requestLocation()
                case .beaconNow:
                    sendBeaconNow()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(Self.consentMessage)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .environment(\.theme, store.theme)
    }

    // Turning beaconing on requires the one-time public-broadcast consent.
    private var beaconEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.aprsBeaconEnabled },
            set: { on in
                if on && !store.aprsBeaconConsented {
                    consentAction = .enableBeacon
                } else {
                    store.aprsBeaconEnabled = on
                    if on { store.locationManager.requestLocation() }
                }
            })
    }

    private func sendBeaconNow() {
        beaconStatus = "Sending…"
        Task {
            let result = await store.aprs.sendPositionBeacon()
            switch result {
            case .sent:       beaconStatus = "Beacon sent"
            case .noLocation(let access): beaconStatus = access.beaconStatus
            case .notReady:   beaconStatus = "Not connected or no callsign set"
            case .outOfBand:  beaconStatus = "Not sent — beacon frequency is outside the amateur band"
            case .noConsent:  beaconStatus = nil
            }
        }
    }
}

// Explains why location-dependent features can't work and links to the
// app's page in Settings (iOS has no public link to Location Services).
private struct LocationUnavailableNotice: View {
    @Environment(\.theme) var t
    @Environment(\.openURL) private var openURL
    var access: LocationAccess
    var consequence: String

    var body: some View {
        ListGroupView(header: "Location") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(t.amber)
                    Text("\(access.explanation ?? "") \(consequence)")
                        .font(.system(size: 15))
                        .foregroundStyle(t.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

private struct PickerRow: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var selection: String
    var options: [String]
    var labels: [String]? = nil
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(t.label)
                Spacer()
                Picker(title, selection: $selection) {
                    ForEach(Array(options.enumerated()), id: \.element) { i, opt in
                        Text(labels?[i] ?? opt).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .tint(t.label2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}

private struct DeviceDetailRow: View {
    @Environment(\.theme) var t
    var label: String
    var value: String
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 15.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}

// MARK: - APRS notifications settings

struct APRSNotificationsView: View {
    @Environment(\.theme) var t
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Bindable var store: RadioStore
    @State private var authDenied = false
    @State private var showDeniedAlert = false

    // Display order for the per-kind toggles.
    private static let kinds: [APRSPacketKind] =
        [.message, .bulletin, .position, .weather, .object, .raw]

    private static let distanceOptions = ["Off", "10 mi", "25 mi", "50 mi"]
    private static let cooldownOptions = ["1 min", "5 min", "10 min", "15 min"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(
                        footer: authDenied
                            ? "Notifications are turned off for Pocket HT. Enable them in iOS Settings › Notifications."
                            : "Packets arrive while the app runs in the background (connected via Bluetooth)."
                    ) {
                        ListRow(title: "Notify on APRS packets", isLast: !authDenied, dense: true,
                                accessory: KVToggle(isOn: enabledBinding) as (any View))
                        if authDenied {
                            Button(action: openNotificationSettings) {
                                ListRow(title: "Open iOS Settings", isLast: true, dense: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ListGroupView(header: "Packet types") {
                        ForEach(Array(Self.kinds.enumerated()), id: \.element) { i, kind in
                            ListRow(title: kind.label, isLast: i == Self.kinds.count - 1, dense: true,
                                    accessory: KVToggle(isOn: kindBinding(kind)) as (any View))
                        }
                    }
                    .disabled(!store.aprsNotify.enabled)
                    .opacity(store.aprsNotify.enabled ? 1 : 0.4)

                    ListGroupView(
                        header: "Filters",
                        footer: "Floods are tamed: repeated beacons from the same station are suppressed for the cooldown. Messages addressed to you always notify."
                    ) {
                        ListRow(title: "Only messages addressed to me", isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.aprsNotify.onlyMessagesToMe) as (any View))
                        PickerRow(title: "Within distance",
                                  selection: distanceBinding,
                                  options: Self.distanceOptions, isLast: false)
                        PickerRow(title: "Beacon cooldown",
                                  selection: cooldownBinding,
                                  options: Self.cooldownOptions, isLast: true)
                    }
                    .disabled(!store.aprsNotify.enabled)
                    .opacity(store.aprsNotify.enabled ? 1 : 0.4)

                    if store.aprsNotify.distanceFilterMi != nil && store.locationManager.access.isUnavailable {
                        LocationUnavailableNotice(
                            access: store.locationManager.access,
                            consequence: "Without your location the distance filter can't apply, so stations at any distance notify.")
                    }

                    ListGroupView(
                        header: "Live activity",
                        footer: "Shows live monitoring status (last station heard + packet count) on the Lock Screen and Dynamic Island while connected."
                    ) {
                        ListRow(title: "Show live activity", isLast: true, dense: true,
                                accessory: KVToggle(isOn: $store.aprsNotify.liveActivityEnabled) as (any View))
                    }

                    if !store.aprsNotify.mutedCallsigns.isEmpty {
                        ListGroupView(header: "Muted stations") {
                            let muted = store.aprsNotify.mutedCallsigns.sorted()
                            ForEach(Array(muted.enumerated()), id: \.element) { i, call in
                                ListRow(title: call, value: "Unmute",
                                        showChevron: false, isLast: i == muted.count - 1, dense: true)
                                    .onTapGesture { store.aprsNotify.mutedCallsigns.remove(call) }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshAuthStatus)
        // Returning from iOS Settings: pick up a permission change.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshAuthStatus() }
        }
        .alert("Notifications are off", isPresented: $showDeniedAlert) {
            Button("Open Settings", action: openNotificationSettings)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notifications for Pocket HT were turned off. To get APRS packet alerts, allow notifications in iOS Settings.")
        }
    }

    // iOS won't re-prompt once denied, so route to Settings instead of
    // silently snapping the toggle back off.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.aprsNotify.enabled },
            set: { on in
                guard on else {
                    store.aprsNotify.enabled = false
                    return
                }
                store.notifications.authorizationStatus { status in
                    if status == .denied {
                        authDenied = true
                        showDeniedAlert = true
                        return
                    }
                    store.notifications.requestAuthorization { granted in
                        authDenied = !granted
                        store.aprsNotify.enabled = granted
                    }
                }
            })
    }

    private func refreshAuthStatus() {
        store.notifications.authorizationStatus { status in
            authDenied = status == .denied
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }

    private func kindBinding(_ k: APRSPacketKind) -> Binding<Bool> {
        Binding(get: { store.aprsNotify.kindEnabled(k) },
                set: { store.aprsNotify.perKind[k.rawValue] = $0 })
    }

    private var distanceBinding: Binding<String> {
        Binding(
            get: {
                guard let mi = store.aprsNotify.distanceFilterMi else { return "Off" }
                return "\(Int(mi)) mi"
            },
            set: {
                store.aprsNotify.distanceFilterMi = Double($0.dropLast(3))  // nil for "Off"
                if store.aprsNotify.distanceFilterMi != nil { store.locationManager.requestLocation() }
            })
    }

    private var cooldownBinding: Binding<String> {
        Binding(
            get: { "\(Int(store.aprsNotify.cooldownSec / 60)) min" },
            set: { store.aprsNotify.cooldownSec = (Double($0.dropLast(4)) ?? 5) * 60 })
    }
}
