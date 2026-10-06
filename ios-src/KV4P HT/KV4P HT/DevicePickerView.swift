import SwiftUI
import CoreBluetooth

// MARK: - BLE Device Picker

struct DevicePickerView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var ble: BLEManager

    private var stateLabel: String {
        switch ble.bleState {
        case .idle:       return "Ready to scan"
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

    var body: some View {
        List {
            Section {
                if ble.bleUnavailable {
                    ContentUnavailableView {
                        Label("Bluetooth Unavailable", systemImage: "bluetooth.slash")
                    } description: {
                        Text("Enable Bluetooth in Settings to connect to your KV4P BLE radio.")
                    }
                    .foregroundStyle(t.label, t.label2)
                    .listRowBackground(Color.clear)
                } else if ble.discoveredDevices.isEmpty && !scanning {
                    ContentUnavailableView {
                        Label("No radios found", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Make sure your KV4P BLE radio is powered on and within range.")
                    } actions: {
                        Button("Scan for Radios") { ble.startScan() }
                            .foregroundStyle(.white)
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .tint(t.accent)
                    }
                    .foregroundStyle(t.label, t.label2)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(ble.discoveredDevices) { device in
                        DeviceRow(device: device, isConnecting: ble.bleState == .connecting || ble.bleState == .connected) {
                            ble.stopScan()
                            ble.connect(device)
                        }
                    }
                }
            } header: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(busy ? t.amber : t.label3)
                        .frame(width: 7, height: 7)
                        .shadow(color: busy ? t.amber : .clear, radius: 3)
                    Text(stateLabel)
                    Spacer()
                    if !ble.discoveredDevices.isEmpty {
                        Text("\(ble.discoveredDevices.count) found")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(t.label2)
                .textCase(nil)
            }
            .listRowBackground(t.surface)

            if showDemo {
                Section {
                    DemoRadioRow(
                        connected: ble.isDemo && ble.bleState == .ready,
                        connecting: ble.isDemo && ble.bleState != .ready
                    ) {
                        ble.connectDemo()
                    }
                } header: {
                    Text("No radio?").foregroundStyle(t.label3)
                } footer: {
                    Text("Simulated signals and APRS traffic. Nothing is transmitted.")
                        .foregroundStyle(t.label3)
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
                Button(role: .close) {
                    ble.stopScan()
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ble.stopScan()
                    ble.startScan()
                } label: {
                    if scanning {
                        ProgressView()
                    } else {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(ble.isDemo || ble.bleState == .connecting || ble.bleState == .connected)
            }
        }
        .onAppear {
            if ble.bleState == .idle { ble.startScan() }
        }
        .onChange(of: ble.bleState) { _, state in
            if state == .ready { dismiss() }
        }
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    @Environment(\.theme) var t
    var device: DiscoveredDevice
    var isConnecting: Bool
    var onTap: () -> Void

    private var rssiIcon: String {
        switch device.rssi {
        case ..<(-80): return "wifi.exclamationmark"
        case ..<(-65): return "wifi"
        default:       return "wifi"
        }
    }

    private var rssiColor: Color {
        switch device.rssi {
        case ..<(-80): return t.amber
        case ..<(-65): return t.label2
        default:       return t.green
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
                    Image(systemName: rssiIcon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(rssiColor)
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
                        .foregroundStyle(t.label3)
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
