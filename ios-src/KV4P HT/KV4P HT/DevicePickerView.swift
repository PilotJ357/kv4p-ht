import SwiftUI
import CoreBluetooth

// MARK: - BLE Device Picker

struct DevicePickerView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var ble: BLEManager
    // .idle covers both "never scanned" and "scan stopped", so only the view
    // can tell the first-open invite from a scan that came up empty.
    @State private var hasScanned = false
    // Set once a scan has run a while with nothing in range.
    @State private var scanIsSlow = false

    // What the radio list area shows. The empty states are mutually exclusive
    // and tied to the BLE state, so none lingers once a connect is under way.
    private enum Phase { case unavailable, invite, searching, noneFound, devices, linking }

    private var phase: Phase {
        if ble.bleUnavailable { return .unavailable }
        if !ble.discoveredDevices.isEmpty { return .devices }
        switch ble.bleState {
        case .scanning:                       return .searching
        case .idle:                           return hasScanned ? .noneFound : .invite
        case .connecting, .connected, .ready: return .linking  // demo radio, nothing to list
        }
    }

    // Header over the device list only; the empty states carry their own message.
    private var stateLabel: String {
        switch ble.bleState {
        case .idle:       return "Tap a radio to connect"
        case .scanning:   return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected:  return "Discovering services…"
        case .ready:      return ble.isDemo ? "Connected to demo radio" : "Connected"
        }
    }

    private var scanning: Bool { ble.bleState == .scanning }

    // Demo row stays available unless a real radio holds (or is reaching for) the link.
    private var showDemo: Bool {
        ble.isDemo || ble.bleState == .idle || ble.bleState == .scanning
    }

    private var busy: Bool { scanning || ble.bleState == .connecting || ble.bleState == .connected }

    // Label color on a prominent button: white, except Night where white would
    // break dark adaptation.
    private var onTint: Color { t.mode == .night ? t.bg : .white }

    private func scan() {
        ble.stopScan()
        ble.startScan()
    }

    var body: some View {
        List {
            radioSection

            if showDemo {
                Section {
                    DemoRadioRow(
                        connected: ble.isDemo && ble.bleState == .ready,
                        connecting: ble.isDemo && ble.bleState != .ready
                    ) {
                        ble.connectDemo()
                    }
                } header: {
                    Text("No radio?").foregroundStyle(t.label2)
                } footer: {
                    Text("Simulated signals and APRS traffic. Nothing is transmitted.")
                        .foregroundStyle(t.label2)
                }
                .listRowBackground(t.surface)
            }

            if ble.bleState == .ready || ble.bleState == .connected {
                Section {
                    Button(role: .destructive) {
                        ble.disconnect()
                    } label: {
                        Text("Disconnect")
                            .fontWeight(.semibold)
                            .foregroundStyle(t.red)
                            .frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(t.redSoft)
            }
        }
        .listRowSeparatorTint(t.sep)
        .scrollContentBackground(.hidden)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Add Radio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CloseButton {
                    ble.stopScan()
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: scan) {
                    if scanning {
                        ProgressView()
                    } else {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(ble.isDemo || ble.bleState == .connecting || ble.bleState == .connected)
            }
        }
        .task {
            hasScanned = hasScanned || scanning
            // The central may not be powered on yet when the sheet opens (first
            // launch, Bluetooth permission prompt) and startScan() silently
            // no-ops until it is, so retry briefly instead of idling.
            for _ in 0..<20 {
                guard ble.bleState == .idle, !hasScanned, !Task.isCancelled else { break }
                ble.startScan()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .task(id: scanning) {
            scanIsSlow = false
            guard scanning else { return }
            hasScanned = true
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            scanIsSlow = true
        }
        .onChange(of: ble.bleState) { _, state in
            if state == .ready { dismiss() }
        }
    }

    // MARK: Radio list / empty states

    @ViewBuilder private var radioSection: some View {
        switch phase {
        case .devices:
            Section {
                ForEach(ble.discoveredDevices) { device in
                    DeviceRow(device: device, isConnecting: ble.bleState == .connecting || ble.bleState == .connected) {
                        ble.stopScan()
                        ble.connect(device)
                    }
                }
                .listRowBackground(t.surface)
            } header: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(busy ? t.amber : t.label3)
                        .frame(width: 7, height: 7)
                        .shadow(color: busy ? t.amber : .clear, radius: 3)
                        .accessibilityHidden(true)
                    Text(stateLabel)
                    Spacer()
                    Text("\(ble.discoveredDevices.count) found")
                }
                .font(.subheadline)
                .foregroundStyle(t.label2)
                .textCase(nil)
            }

        case .unavailable:
            stateSection(title: "Bluetooth Unavailable",
                         message: "Enable Bluetooth in Settings to connect to your KV4P BLE radio.") {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(t.label2)
            }

        case .invite:
            stateSection(title: "Find your radio",
                         message: "Power on your KV4P BLE radio and keep it close, then scan.") {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(t.accent)
            } actions: {
                scanButton("Scan for Radios")
            }

        case .searching:
            stateSection(title: "Searching for radios…",
                         message: scanIsSlow
                             ? "Still looking. Make sure your KV4P BLE radio is powered on and within range."
                             : "Radios in range will appear here.") {
                ProgressView().controlSize(.large).tint(t.accent)
            }

        case .noneFound:
            stateSection(title: "No radios found",
                         message: "Make sure your KV4P BLE radio is powered on and within range.") {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(t.label2)
            } actions: {
                scanButton("Scan Again")
            }

        case .linking:
            EmptyView()
        }
    }

    private func stateSection<Icon: View, Actions: View>(
        title: String, message: String,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        Section {
            PickerStateView(title: title, message: message, icon: icon, actions: actions)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private func stateSection<Icon: View>(
        title: String, message: String, @ViewBuilder icon: () -> Icon
    ) -> some View {
        stateSection(title: title, message: message, icon: icon) {}
    }

    private func scanButton(_ title: String) -> some View {
        Button(action: scan) {
            Text(title).foregroundStyle(onTint)
        }
        .glassProminentButtonStyle()
        .controlSize(.large)
        .tint(t.accent)
    }
}

// MARK: - Empty / progress state

private struct PickerStateView<Icon: View, Actions: View>: View {
    @Environment(\.theme) var t
    var title: String
    var message: String
    @ViewBuilder var icon: Icon
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                icon
                    .font(.largeTitle)
                    .frame(minHeight: 44)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(t.label)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(t.label2)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    @Environment(\.theme) var t
    var device: DiscoveredDevice
    var isConnecting: Bool
    var onTap: () -> Void

    // Signal bars filled by strength; the dBm figure sits underneath.
    private var signalLevel: Double {
        switch device.rssi {
        case (-60)...:     return 1
        case (-70)...:     return 0.75
        case (-80)...:     return 0.5
        case (-90)...:     return 0.25
        default:           return 0
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(t.accentSoft)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(t.accent)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(t.label)
                    Text(device.id.uuidString.prefix(8).uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(t.label3)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Image(systemName: "cellularbars", variableValue: signalLevel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(t.label2)
                        .accessibilityLabel("Signal strength")
                    Text("\(device.rssi) dBm")
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(t.label3)
                }

                if isConnecting {
                    ProgressView().tint(t.accent)
                }
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .disabled(isConnecting)
    }
}

// MARK: - Demo radio

private struct DemoRadioRow: View {
    @Environment(\.theme) var t
    var connected: Bool
    var connecting: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(t.amber.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(t.amber)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo Radio")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(t.label)
                    Text("Try the app with a simulated radio")
                        .font(.footnote)
                        .foregroundStyle(t.label2)
                }

                Spacer()

                if connecting {
                    ProgressView().tint(t.accent)
                } else if connected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(t.green)
                }
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .disabled(connected || connecting)
    }
}
