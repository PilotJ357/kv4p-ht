import SwiftUI
import UserNotifications

// MARK: - More Tab

struct MoreView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        Form {
            // Radio rows
            Section {
                NavigationLink { DeviceInfoView(store: store) } label: {
                    SettingsValueRow(
                        title: "Device & firmware",
                        value: store.ble.hello.map { "v\($0.firmwareVersion)" } ?? "–",
                        icon: IconTile(color: t.accent, systemImage: "antenna.radiowaves.left.and.right")
                    )
                }
                NavigationLink { BeaconSettingsView(store: store) } label: {
                    SettingsValueRow(
                        title: "My position & beacon",
                        value: store.aprsBeaconEnabled ? "On" : "Off",
                        icon: IconTile(color: t.green, systemImage: "location.fill")
                    )
                }
                NavigationLink { TranscriptLogView(store: store) } label: {
                    SettingsValueRow(
                        title: "Transcript log",
                        value: store.transcriptLog.entries.isEmpty ? nil : "\(store.transcriptLog.entries.count)",
                        icon: IconTile(color: t.amber, systemImage: "captions.bubble.fill")
                    )
                }
            }
            .settingsRowStyle(t)

            // Settings / Privacy rows
            Section {
                NavigationLink { SettingsView(store: store) } label: {
                    SettingsValueRow(
                        title: "Settings",
                        // Neutral gray like iOS Settings; Night has no gray, so its dimmed red.
                        icon: IconTile(color: t.mode == .night ? t.label2 : Color(.systemGray), systemImage: "gearshape.fill")
                    )
                }
                NavigationLink { PrivacyPolicyView() } label: {
                    SettingsValueRow(
                        title: "Privacy",
                        icon: IconTile(color: t.green, systemImage: "hand.raised.fill")
                    )
                }
                NavigationLink { AboutView(store: store) } label: {
                    SettingsValueRow(
                        title: "About",
                        icon: IconTile(color: t.accent, systemImage: "info.circle.fill")
                    )
                }
            } footer: {
                Text("Pocket HT · For KV4P BLE radios · GPLv3")
                    .foregroundStyle(t.label3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .settingsRowStyle(t)
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    var showsClose = false  // presented as a sheet (Voice tab) rather than pushed
    @State private var captionsAlert: CaptionsStatus? = nil
    @Environment(\.openURL) private var openURL

    private let aprsFrequencies = ["Current"] + APRSRegion.all.map(\.setting)
    private let aprsFrequencyLabels = ["Current"] + APRSRegion.all.map(\.label)

    private var captionsFooter: String {
        let onDevice = "On-device speech recognition. No data sent to the cloud. Saved transcripts stay on this device."
        switch store.captionsStatus {
        case .needsNewerOS, .denied, .restricted, .unavailable:
            return store.captionsStatus.message(language: store.captionLanguage) ?? onDevice
        case .off, .needsPermission, .listening:
            return onDevice
        }
    }

    // Shown off and locked before iOS 26; the stored preference is kept for
    // after an OS update.
    private var captionsBinding: Binding<Bool> {
        store.captionsStatus == .needsNewerOS ? .constant(false) : $store.liveCaptions
    }

    private func openAppSettings() {
        openURL(CaptionsStatus.appSettingsURL)
    }

    var body: some View {
        Form {
            // APRS
            Section {
                SettingsTextField(title: "Callsign",  text: $store.callsign, placeholder: "N0CALL")
                SettingsTextField(title: "APRS SSID", text: $store.aprsSSID, placeholder: "Optional", autocap: .never)
                PickerRow(title: "APRS frequency",
                          selection: $store.aprsBeaconFrequency,
                          options: aprsFrequencies,
                          labels: aprsFrequencyLabels)
                SettingsToggle(title: "Silence audio on APRS freq", isOn: $store.silenceRxOnAprsFreq)
                SettingsToggle(title: "Digipeat packets", isOn: $store.aprsDigipeatEnabled)
            } header: {
                Text("APRS").foregroundStyle(t.label2)
            } footer: {
                Text("APRS packets are decoded regardless of squelch. Silencing mutes RX audio while tuned to your APRS frequency so you don't hear packet noise.\n\nDigipeat packets makes this radio a fill-in digipeater: packets whose next hop is WIDE1-1 or your callsign are retransmitted with your callsign on the simplex frequency they were heard on, once squelch closes. Each packet is repeated at most once, and your own packets never are.")
                    .foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            // Notifications
            Section {
                NavigationLink {
                    APRSNotificationsView(store: store)
                } label: {
                    SettingsValueRow(title: "APRS notifications",
                                     value: store.aprsNotify.enabled ? "On" : "Off")
                }
            } header: {
                Text("Notifications").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            // Radio
            Section {
                SquelchSliderRow(store: store)
                TXPowerRow(store: store)
                SettingsValueRow(title: "Band",
                                 value: store.ble.hello.map { $0.rfModuleType == 0 ? "VHF" : "UHF" } ?? "–")
                TxTimeoutRow(store: store)
            } header: {
                Text("Radio").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            // Audio filters
            Section {
                SettingsToggle(title: "High-pass", isOn: $store.filterHighPass)
                SettingsToggle(title: "Low-pass",  isOn: $store.filterLowPass)
                BandwidthRow(store: store)
            } header: {
                Text("Audio filters").foregroundStyle(t.label2)
            } footer: {
                Text("Controlled by firmware.").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            // Transcription
            Section {
                SettingsToggle(title: "Live captions", isOn: captionsBinding)
                    .disabled(store.captionsStatus == .needsNewerOS)
                if store.captionsStatus.opensSettings {
                    Button("Open Settings", action: openAppSettings)
                        .foregroundStyle(t.accent)
                }
                SettingsToggle(title: "Save transcripts", isOn: $store.saveTranscripts)
                NavigationLink {
                    TranscriptLogView(store: store)
                } label: {
                    SettingsValueRow(title: "Transcript log",
                                     value: "\(store.transcriptLog.entries.count)")
                }
            } header: {
                Text("Transcription").foregroundStyle(t.label2)
            } footer: {
                Text(captionsFooter).foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            // Appearance
            Section {
                Picker("Appearance", selection: $store.themeMode) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SettingsToggle(title: "Sticky PTT", isOn: $store.stickyPTT)
            } header: {
                Text("Appearance").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
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
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
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
        LabeledContent {
            Picker("TX power", selection: $store.txPower) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 140)
            .disabled(!store.radio.hasHighLowPowerSwitch)
        } label: {
            Text("TX power")
                .foregroundStyle(t.label)
        }
    }
}

// MARK: - TX time-out picker

private struct TxTimeoutRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        Picker(selection: $store.txTimeoutSeconds) {
            ForEach(TxTimeout.options, id: \.self) { secs in
                Text(TxTimeout.label(secs)).tag(secs)
            }
        } label: {
            Text("TX time-out")
                .foregroundStyle(t.label)
        } currentValueLabel: {
            Text(TxTimeout.label(store.txTimeoutSeconds))
                .foregroundStyle(t.label2)
        }
        .pickerStyle(.menu)
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
        LabeledContent {
            Picker("Bandwidth", selection: bwBinding) {
                Text("Wide").tag("Wide")
                Text("Narrow").tag("Narrow")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 160)
        } label: {
            Text("Bandwidth")
                .foregroundStyle(t.label)
        }
    }
}

// MARK: - Squelch slider

private struct SquelchSliderRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Squelch")
                    .foregroundStyle(t.label)
                Spacer()
                Text("Level \(store.squelch)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(t.label2)
            }
            SquelchSlider(store: store)
                .tint(t.accent)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Device Info stub

struct DeviceInfoView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        Form {
            Section {
                if let hello = store.ble.hello {
                    DeviceDetailRow(label: "Firmware", value: "v\(hello.firmwareVersion)")
                    DeviceDetailRow(label: "Radio Module", value: hello.radioModuleFound ? "Found" : "Not found")
                    DeviceDetailRow(label: "RF Module", value: hello.rfModuleType == 0 ? "VHF" : "UHF")
                    DeviceDetailRow(label: "Freq Range", value: "\(String(format: "%.1f", hello.minFreq))–\(String(format: "%.1f", hello.maxFreq)) MHz")
                    DeviceDetailRow(label: "Features", value: "0x\(String(hello.features, radix: 16))")
                } else {
                    Text("No device connected")
                        .foregroundStyle(t.label2)
                }
            } header: {
                Text("Hello Frame").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Device & Firmware")
        .navigationBarTitleDisplayMode(.large)
        .environment(\.theme, store.theme)
    }
}

// MARK: - Beacon settings

struct BeaconSettingsView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var beaconStatus: String? = nil
    @State private var consentAction: ConsentAction? = nil

    // What to do once the user accepts the public-broadcast disclosure.
    private enum ConsentAction { case enableBeacon, beaconNow }

    static let consentMessage = "Position beacons transmit your callsign and location over the air on APRS. Anyone listening can receive them, and internet gateways (iGates) relay them to public websites such as aprs.fi, where they are archived and can't be deleted.\n\nBeacons are sent at the chosen interval while the radio is connected and the app is open; they pause in the background. Turn on Approximate position to round your location to about 1 km."

    // Curated APRS symbols (table "/"), mirroring Android's APRSIconType subset.
    private static let symbols: [(code: String, label: String)] = [
        ("[", "Person"), ("-", "House"), (">", "Car"), ("b", "Bicycle"),
        ("v", "Van"), ("k", "Truck"), ("Y", "Sailboat"), ("$", "Phone"),
    ]

    private let intervals = [5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                SettingsToggle(title: "Beacon position", isOn: beaconEnabledBinding)
                PickerRow(title: "Interval",
                          selection: Binding(
                              get: { "\(store.aprsBeaconIntervalMin) min" },
                              set: { store.aprsBeaconIntervalMin = Int($0.dropLast(4)) ?? 15 }),
                          options: intervals.map { "\($0) min" })
                SettingsToggle(title: "Interrupt reception", isOn: $store.aprsBeaconInterruptRx)
                SettingsToggle(title: "Approximate position", isOn: $store.aprsPositionApprox)
            } header: {
                Text("Position beacon").foregroundStyle(t.label2)
            } footer: {
                Text("Off by default. When on, publicly broadcasts your callsign and GPS position over APRS at the chosen interval while the radio is connected and the app is open. Scheduled beacons pause while the app is in the background, and a beacon is skipped rather than sent with a location fix older than \(Int(APRSController.beaconFixMaxAge / 60)) minutes. Requires a callsign and APRS frequency configured in Settings.\n\nWith Interrupt reception off, a scheduled beacon that comes due while a signal is being received waits, re-checking every \(Int(BeaconDeferGate.retryInterval)) s until the channel is quiet. Beacon now always sends immediately.")
                    .foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            if store.locationManager.access.isUnavailable {
                LocationUnavailableNotice(
                    access: store.locationManager.access,
                    consequence: "Position beacons can't be sent until it's available.")
            }

            Section {
                PickerRow(title: "Symbol",
                          selection: Binding(
                              get: {
                                  Self.symbols.first { $0.code == store.aprsSymbol }?.label
                                      ?? Self.symbols[0].label
                              },
                              set: { label in
                                  store.aprsSymbol = Self.symbols.first { $0.label == label }?.code ?? "["
                              }),
                          options: Self.symbols.map(\.label))
            } header: {
                Text("Map symbol").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            Section {
                Button {
                    if store.aprsBeaconConsented {
                        sendBeaconNow()
                    } else {
                        consentAction = .beaconNow
                    }
                } label: {
                    Label("Beacon now", systemImage: "dot.radiowaves.left.and.right")
                        .fontWeight(.semibold)
                        // White would break Night's dark adaptation.
                        .foregroundStyle(t.mode == .night ? t.bg : .white)
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButtonStyle()
                .controlSize(.large)
                .tint(t.green)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let status = beaconStatus {
                    Text(status)
                        .foregroundStyle(t.label2)
                        .frame(maxWidth: .infinity)
                }
            }

            if store.aprsBeaconConsented {
                Section {
                    Button(role: .destructive) {
                        store.aprsBeaconConsented = false
                        beaconStatus = nil
                    } label: {
                        Text("Stop sharing my position")
                            .foregroundStyle(t.red)
                            .frame(maxWidth: .infinity)
                    }
                }
                .settingsRowStyle(t)
            }
        }
        .scrollContentBackground(.hidden)
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
            let result = await store.aprs.sendManualBeacon()
            switch result {
            case .sent:       beaconStatus = "Beacon sent"
            case .noLocation(let access): beaconStatus = access.beaconStatus
            case .notReady:   beaconStatus = "Not connected or no callsign set"
            case .outOfBand:  beaconStatus = "Not sent — beacon frequency is outside the amateur band"
            case .staleLocation: beaconStatus = "Not sent — couldn't get a current location fix"
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
        Section {
            Label {
                Text("\(access.explanation ?? "") \(consequence)")
                    .foregroundStyle(t.label)
            } icon: {
                Image(systemName: "location.slash")
                    .foregroundStyle(t.amber)
            }
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .foregroundStyle(t.accent)
        } header: {
            Text("Location").foregroundStyle(t.label2)
        }
        .settingsRowStyle(t)
    }
}

private struct SettingsToggle: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .foregroundStyle(t.label)
        }
        .tint(t.green)
    }
}

private struct SettingsValueRow: View {
    @Environment(\.theme) var t
    var title: String
    var value: String? = nil
    var icon: IconTile? = nil

    var body: some View {
        LabeledContent {
            if let value {
                Text(value)
                    .foregroundStyle(t.label2)
            }
        } label: {
            if let icon {
                Label {
                    Text(title)
                        .foregroundStyle(t.label)
                } icon: {
                    icon
                }
            } else {
                Text(title)
                    .foregroundStyle(t.label)
            }
        }
    }
}

private struct SettingsTextField: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var text: String
    var placeholder: String
    var autocap: TextInputAutocapitalization = .characters

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(placeholder).foregroundStyle(t.label3))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(t.label2)
                .textInputAutocapitalization(autocap)
                .autocorrectionDisabled()
        } label: {
            Text(title)
                .foregroundStyle(t.label)
        }
    }
}

private struct PickerRow: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var selection: String
    var options: [String]
    var labels: [String]? = nil

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.element) { i, opt in
                Text(labels?[i] ?? opt).tag(opt)
            }
        } label: {
            Text(title)
                .foregroundStyle(t.label)
        } currentValueLabel: {
            Text(options.firstIndex(of: selection)
                .map { labels?[$0] ?? options[$0] } ?? selection)
                .foregroundStyle(t.label2)
        }
        .pickerStyle(.menu)
    }
}

private struct DeviceDetailRow: View {
    @Environment(\.theme) var t
    var label: String
    var value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .foregroundStyle(t.label2)
        } label: {
            Text(label)
                .foregroundStyle(t.label)
        }
    }
}

private extension View {
    func settingsRowStyle(_ t: AppTheme) -> some View {
        listRowBackground(t.surface)
            .listRowSeparatorTint(t.sep)
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
        Form {
            Section {
                SettingsToggle(title: "Notify on APRS packets", isOn: enabledBinding)
                if authDenied {
                    Button("Open iOS Settings", action: openNotificationSettings)
                        .foregroundStyle(t.accent)
                }
            } footer: {
                Text(authDenied
                     ? "Notifications are turned off for Pocket HT. Enable them in iOS Settings › Notifications."
                     : "Packets arrive while the app runs in the background (connected via Bluetooth).")
                    .foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            Section {
                ForEach(Self.kinds, id: \.self) { kind in
                    SettingsToggle(title: kind.label, isOn: kindBinding(kind))
                }
            } header: {
                Text("Packet types").foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)
            .disabled(!store.aprsNotify.enabled)
            .opacity(store.aprsNotify.enabled ? 1 : 0.4)

            Section {
                SettingsToggle(title: "Only messages addressed to me", isOn: $store.aprsNotify.onlyMessagesToMe)
                PickerRow(title: "Within distance",
                          selection: distanceBinding,
                          options: Self.distanceOptions)
                PickerRow(title: "Beacon cooldown",
                          selection: cooldownBinding,
                          options: Self.cooldownOptions)
            } header: {
                Text("Filters").foregroundStyle(t.label2)
            } footer: {
                Text("Floods are tamed: repeated beacons from the same station are suppressed for the cooldown. Messages addressed to you always notify.")
                    .foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)
            .disabled(!store.aprsNotify.enabled)
            .opacity(store.aprsNotify.enabled ? 1 : 0.4)

            if store.aprsNotify.distanceFilterMi != nil && store.locationManager.access.isUnavailable {
                LocationUnavailableNotice(
                    access: store.locationManager.access,
                    consequence: "Without your location the distance filter can't apply, so stations at any distance notify.")
            }

            Section {
                SettingsToggle(title: "Show live activity", isOn: $store.aprsNotify.liveActivityEnabled)
            } header: {
                Text("Live activity").foregroundStyle(t.label2)
            } footer: {
                Text("Shows live monitoring status (last station heard + packet count) on the Lock Screen and Dynamic Island while connected.")
                    .foregroundStyle(t.label2)
            }
            .settingsRowStyle(t)

            if !store.aprsNotify.mutedCallsigns.isEmpty {
                Section {
                    ForEach(store.aprsNotify.mutedCallsigns.sorted(), id: \.self) { call in
                        Button { store.aprsNotify.mutedCallsigns.remove(call) } label: {
                            SettingsValueRow(title: call, value: "Unmute")
                        }
                    }
                } header: {
                    Text("Muted stations").foregroundStyle(t.label2)
                }
                .settingsRowStyle(t)
            }
        }
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.large)
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
