import SwiftUI
import AVFoundation
import Combine
import AVKit
import MediaPlayer
import UIKit

// MARK: - Voice Tab root

struct VoiceView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showCaptions = false
    @State private var showDevicePicker = false
    @State private var showSettings = false
    @State private var stageLayout: StageLayout = .regular

    var body: some View {
        VStack(spacing: 0) {
            DeviceStrip(
                connected: store.ble.bleState == .ready,
                demo: store.ble.isDemo,
                action: { showDevicePicker = true }
            )

            Picker("Mode", selection: $store.voiceMode) {
                ForEach(VoiceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 2)

            switch store.voiceMode {
            case .vfo:  VFOBody(store: store, layout: stageLayout)
            case .scan: ScanBody(store: store)
            }

            // Wide stage centers itself in the leftover height.
            if stageLayout != .wide {
                Spacer(minLength: 0)
            }
        }
        .onGeometryChange(for: StageLayout.self) { StageLayout(size: $0.size) } action: { stageLayout = $0 }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCaptions = true } label: {
                    Label("Captions", systemImage: "captions.bubble")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showCaptions) {
            NavigationStack {
                CaptionsSheet(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDevicePicker) {
            NavigationStack {
                DevicePickerView(ble: store.ble)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(store: store, showsClose: true)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: store.voiceMode) { _, mode in
            if mode != .scan { store.stopScan() }
        }
        .onAppear {
            if store.ble.bleState == .idle { showDevicePicker = true }
        }
        .onChange(of: store.isSquelched) { _, _ in
            store.checkSquelchTransition()
        }
        .onChange(of: store.ble.bleState) { _, state in
            if state == .ready {
                store.setupAudioSampleHook()
            }
        }
    }
}

// MARK: - Stage layout

// Picked from the space the Voice tab actually gets, not the device: iPhone
// Duo resizes the app on fold/unfold, and its inner display is wide but no
// taller than the outer one.
nonisolated enum StageLayout: Equatable {
    case regular, compact, wide

    init(size: CGSize) {
        if size.width >= 700 { self = .wide }
        else if size.height < 650 { self = .compact }
        else { self = .regular }
    }
}

// MARK: - VFO body

private struct VFOBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    var layout: StageLayout

    var body: some View {
        // Memory match supplies only name/description; freq, offset, and
        // tone always display firmware-applied state.
        let matched = store.memory(for: store.currentFreq)
        // Band from HELLO (0 = VHF, else UHF); omit until the module reports.
        let band = store.ble.hello.map { $0.rfModuleType == 0 ? "VHF · " : "UHF · " } ?? ""
        RadioStage(
            store:        store,
            channelName:  matched?.name ?? store.currentFreqString,
            channelDesc:  matched?.notes ?? "",
            freq:         store.currentFreqString,
            offset:       store.currentOffsetString,
            tone:         store.currentToneString,
            modeLabel:    band + "VFO",
            freqEditable: true,
            layout:       layout
        )
    }
}

// MARK: - Shared radio stage

private struct RadioStage: View {
    @Environment(\.theme) var t
    @Environment(\.openURL) private var openURL
    @Bindable var store: RadioStore
    var channelName:  String
    var channelDesc:  String
    var freq:         String
    var offset:       String
    var tone:         String
    var modeLabel:    String
    var freqEditable: Bool = false
    var layout:       StageLayout = .regular
    @State private var squelchDragging = false

    private var compact: Bool { layout == .compact }

    @GestureState private var pttDown = false
    @State private var stickyPttActive = false
    // Hold-to-talk press that actually requested PTT (passed the gate).
    @State private var holdKeyed = false
    @State private var showNumpad = false
    @State private var showOffsetTone = false
    @State private var showLicenseAck = false

    // Applied state (firmware DeviceState) drives the badge and frequency
    // color; local request state drives the PTT button visual. The S-meter
    // uses store.meterSuppressed, which covers both plus a post-TX hold.
    private var rxState: RadioRxState {
        store.rxMode
    }

    private var pttRequested: Bool {
        pttDown || (store.stickyPTT && stickyPttActive)
    }

    private var txApplied: Bool {
        store.rxMode == .tx
    }

    private var txBlocked: Bool {
        store.isTxOutOfBand
    }

    private var micDenied: Bool {
        store.voicePTTGate == .micDenied
    }

    // Mode chip doubles as the TX time-out countdown in its last seconds.
    private var chipLabel: String {
        if let remaining = store.txTimeoutRemaining { return "TX ends in \(remaining)s" }
        return modeLabel
    }

    private var showReleaseNotice: Binding<Bool> {
        Binding(get: { store.pttReleaseNotice != nil },
                set: { if !$0 { store.pttReleaseNotice = nil } })
    }

    private func sendPTT(_ on: Bool) {
        store.sendRadioState(freq: Float(freq) ?? 146.52, ptt: on)
    }

    // Runs the gate for a press that would key. Returns true if PTT went out.
    private func keyIfAllowed() -> Bool {
        switch store.voicePTTGate {
        case .key:             sendPTT(true); return true
        case .needsLicenseAck: showLicenseAck = true
        case .requestMic:      store.requestMicPermission()
        case .micDenied:       openAppSettings()
        case .outOfBand:       break
        }
        return false
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    var body: some View {
        Group {
            if layout == .wide {
                // Readout beside the transmit controls so a wide window (iPhone
                // Duo inner display) doesn't stretch everything edge to edge.
                HStack(alignment: .center, spacing: 32) {
                    VStack(spacing: 0) {
                        readout
                        infoPills
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        pttControl
                        sliders
                    }
                    .frame(width: 320)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    readout
                    infoPills
                        .padding(.horizontal, 20)
                    // Full width: the glass slider thumb is a fixed size and
                    // swamps a track squeezed in beside the PTT button.
                    sliders
                        .padding(.horizontal, 20)
                        .padding(.bottom, compact ? 10 : 16)
                    pttControl
                }
            }
        }
        .padding(.bottom, 8)
        // The controller already dropped PTT for the out-of-band tune; unlatch
        // sticky PTT so it doesn't show ON AIR or carry over once back in band.
        .onChange(of: txBlocked) { _, blocked in
            if blocked { stickyPttActive = false }
        }
        // The store dropped PTT itself (TX time-out or backgrounding).
        .onChange(of: store.pttForcedReleaseCount) { _, _ in
            stickyPttActive = false
            holdKeyed = false
        }
        .sensoryFeedback(.warning, trigger: store.txTimeoutRemaining != nil) { _, warning in warning }
        .alert("Transmit stopped", isPresented: showReleaseNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.pttReleaseNotice ?? "")
        }
        .alert("Amateur radio license required", isPresented: $showLicenseAck) {
            Button("I'm Licensed") { store.txLicenseAcknowledged = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Transmitting requires a valid amateur radio license. Only transmit if you're licensed and on frequencies your license permits.")
        }
        .sheet(isPresented: $showNumpad) {
            FreqNumpad(store: store, currentFreq: freq)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.height(540), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showOffsetTone) {
            OffsetToneSheet(store: store)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // Mode chip, frequency, channel name, S-meter.
    private var readout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(txApplied ? t.red : t.accent)
                    .frame(width: 6, height: 6)
                Text(chipLabel)
                    .font(.system(size: 12.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(t.label)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(t.fill)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.top, compact ? 12 : 20)

            Group {
                if freqEditable {
                    Button { showNumpad = true } label: {
                        FreqReadout(freq: freq, size: compact ? 62 : 74, state: rxState)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    FreqReadout(freq: freq, size: compact ? 62 : 74, state: rxState)
                }
            }
            .padding(.top, 6)

            VStack(spacing: 2) {
                Text(channelName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(t.label)
                Text(channelDesc)
                    .font(.system(size: 13.5))
                    .foregroundStyle(t.label2)
            }
            .padding(.top, 2)

            HStack(spacing: 14) {
                SMeter(level: store.meterSuppressed ? 0 : store.signalLevel,
                       active: !store.meterSuppressed, rawRSSI: store.rawRSSI)
                RxBadge(state: rxState)
            }
            .padding(.top, 8)
        }
    }

    // Offset/tone open the channel-config editor.
    private var infoPills: some View {
        HStack(spacing: 8) {
            Button { showOffsetTone = true } label: {
                InfoPill(key: "Offset", value: offset)
            }
            .buttonStyle(.plain)
            Button { showOffsetTone = true } label: {
                InfoPill(key: "Tone", value: tone)
            }
            .buttonStyle(.plain)
            Menu {
                Picker("TX power", selection: $store.txPower) {
                    ForEach(["Low", "High"], id: \.self) { Text($0).tag($0) }
                }
            } label: {
                InfoPill(key: "Power", value: store.txPower)
            }
            .buttonStyle(.plain)
            .disabled(!store.radio.hasHighLowPowerSwitch)
        }
        .padding(.top, 10)
        .padding(.bottom, compact ? 10 : 14)
    }

    private var pttControl: some View {
        VStack(spacing: 8) {
            if store.stickyPTT {
                PTTButton(isDown: stickyPttActive, rxOnly: txBlocked, noMic: micDenied,
                          diameter: compact ? 136 : 168)
                    .onTapGesture {
                        guard !txBlocked else { return }
                        if stickyPttActive {
                            stickyPttActive = false
                            sendPTT(false)
                        } else {
                            stickyPttActive = keyIfAllowed()
                        }
                    }
            } else {
                PTTButton(isDown: holdKeyed, rxOnly: txBlocked, noMic: micDenied,
                          diameter: compact ? 136 : 168)
                    .gesture(
                        LongPressGesture(minimumDuration: 0.01)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .updating($pttDown) { _, state, _ in state = true }
                            .onEnded { _ in sendPTT(false) }
                    )
                    .allowsHitTesting(!txBlocked)
                    .onChange(of: pttDown) { _, down in
                        if down {
                            holdKeyed = keyIfAllowed()
                        } else {
                            holdKeyed = false
                            sendPTT(false)
                        }
                    }
            }
            if micDenied && !txBlocked {
                Button(action: openAppSettings) {
                    Label("Open Settings", systemImage: "gear")
                        .font(.footnote.weight(.semibold))
                }
                .glassButtonStyle()
                .controlSize(.small)
                .accessibilityHint("Allow microphone access to transmit voice")
            }
        }
    }

    // System volume (with output picker) and squelch.
    private var sliders: some View {
        VStack(spacing: compact ? 8 : 12) {
            SliderRow(title: "Volume") {
                SystemVolumeView(tint: UIColor(t.accent))
            } trailing: {
                RoutePicker(tint: UIColor(t.label2), activeTint: UIColor(t.accent))
                    .frame(width: 24)
            }
            SliderRow(title: "Squelch") {
                // Drags send the level to the radio once, on release (per-tick
                // writes made the thumb bounce); VoiceOver adjustments send it immediately.
                Slider(
                    value: Binding(
                        get: { Double(store.squelch) },
                        set: {
                            store.squelch = UInt8($0.rounded())
                            if !squelchDragging { store.radio.setSquelch(store.squelch) }
                        }
                    ),
                    in: 0...9, step: 1
                ) { editing in
                    squelchDragging = editing
                    if !editing { store.radio.setSquelch(store.squelch) }
                }
                .accessibilityLabel("Squelch")
                .accessibilityValue("\(store.squelch)")
            } trailing: {
                Text("Level \(store.squelch)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(t.label2)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - PTT Button

struct PTTButton: View {
    @Environment(\.theme) var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isDown: Bool
    // TX frequency is outside the amateur band; the button is inert.
    var rxOnly: Bool = false
    // Microphone access denied; voice PTT can't key. RX ONLY wins if both.
    var noMic: Bool = false
    // Outer ring; inner ring, face, and glyph scale with it.
    var diameter: CGFloat = 168

    private var scale: CGFloat { diameter / 168 }
    private var inert: Bool { rxOnly || noMic }
    private var onAir: Bool { isDown && !inert }
    private var ringColor: Color { inert ? t.label3 : (onAir ? t.red : t.accent) }
    private var labelColor: Color { inert ? t.label2 : .white }
    private var stateLabel: String {
        if rxOnly { return "RX ONLY" }
        if noMic { return "NO MIC" }
        return onAir ? "ON AIR" : "HOLD"
    }
    private var a11yLabel: String {
        if rxOnly { return "Receive only: outside the amateur band" }
        if noMic { return "Push to talk unavailable: microphone access denied" }
        return "Push to talk"
    }
    private var grad: LinearGradient {
        if inert {
            return LinearGradient(colors: [t.fill, t.fill2], startPoint: .top, endPoint: .bottom)
        } else if onAir {
            return LinearGradient(colors: [Color(hex: "FF6B61"), t.red], startPoint: .top, endPoint: .bottom)
        } else {
            return LinearGradient(colors: [t.isDark ? Color(hex: "3A9BFF") : Color(hex: "3F96FF"), t.accent], startPoint: .top, endPoint: .bottom)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor, lineWidth: 2)
                .opacity(onAir ? 0.5 : 0.22)
                .frame(width: diameter, height: diameter)
            Circle()
                .stroke(ringColor, lineWidth: 1.5)
                .opacity(onAir ? 0.35 : 0.14)
                .frame(width: 148 * scale, height: 148 * scale)
            Circle()
                .fill(grad)
                .frame(width: 132 * scale, height: 132 * scale)
                .shadow(color: inert ? .clear : (onAir ? t.red.opacity(0.53) : t.accent.opacity(0.27)), radius: 22)
                .shadow(color: Color.black.opacity(0.35), radius: 15, y: 10)
                .overlay(
                    VStack(spacing: 5) {
                        Image(systemName: inert ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 36 * scale, weight: .medium))
                            .foregroundStyle(labelColor)
                        Text(stateLabel)
                            .font(.system(size: 11.5, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(labelColor)
                    }
                )
        }
        .scaleEffect(onAir && !reduceMotion ? 0.97 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: onAir)
        .accessibilityLabel(a11yLabel)
    }
}

// MARK: - Slider row

// Named slider: caption and trailing accessory (route picker, level) on
// one line, the slider full width underneath.
private struct SliderRow<Content: View, Trailing: View>: View {
    @Environment(\.theme) var t
    var title: String
    @ViewBuilder var slider: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(t.label2)
                    .accessibilityHidden(true)
                Spacer()
                trailing()
                    .frame(height: 24)
            }
            slider()
                .tint(t.accent)
        }
    }
}

// MARK: - System volume

#if targetEnvironment(simulator)
// The simulator has no system volume, so MPVolumeView draws nothing there.
// Stand-in slider keeps the layout reviewable; it changes no audio.
private struct SystemVolumeView: View {
    var tint: UIColor
    @State private var level = 0.5

    var body: some View {
        Slider(value: $level).accessibilityLabel("Volume")
    }
}
#else
// The system volume view: drives the real output volume and tracks hardware
// buttons itself. Its built-in route button is hidden in favor of
// RoutePicker, which sits in the row's trailing slot.
private struct SystemVolumeView: UIViewRepresentable {
    var tint: UIColor

    private final class SliderOnly: MPVolumeView {
        override func layoutSubviews() {
            super.layoutSubviews()
            for case let button as UIButton in subviews { button.isHidden = true }
        }

        // MPVolumeView pins its slider to the top edge, and re-lays it out on
        // route changes without a layoutSubviews pass, so center it through
        // the slider-rect hook it consults on every layout.
        override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
            var rect = super.volumeSliderRect(forBounds: bounds)
            rect.origin.y = (bounds.height - rect.height) / 2
            return rect
        }
    }

    func makeUIView(context: Context) -> MPVolumeView { SliderOnly(frame: .zero) }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = tint
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MPVolumeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 34)
    }
}
#endif

// Audio output picker (speaker, Bluetooth, AirPlay).
private struct RoutePicker: UIViewRepresentable {
    var tint: UIColor
    var activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = activeTint
    }
}

// MARK: - Frequency readout

struct FreqReadout: View {
    @Environment(\.theme) var t
    var freq: String
    var size: CGFloat = 74
    var state: RadioRxState = .idle

    private var color: Color {
        switch state {
        case .tx:   return t.red
        case .rx:   return t.green
        case .idle: return t.label
        }
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(freq)
                .font(.system(size: size, weight: .bold, design: .default).monospacedDigit())
                .tracking(-1.5)
                .foregroundStyle(color)
            Text("MHz")
                .font(.system(size: size * 0.27, weight: .semibold))
                .foregroundStyle(t.label2)
        }
    }
}

// MARK: - Scan screen

private struct ScanBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var scanList: [Memory] { store.scanList }

    var body: some View {
        if scanList.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(t.label3)
                Text("No scan channels")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(t.label)
                Text("Add memories to build a scan list.")
                    .font(.system(size: 14))
                    .foregroundStyle(t.label2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                // Current freq readout
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: store.scanPaused ? "pause.circle.fill" : "barcode.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                        Text(store.scanPaused ? "PAUSED" : (store.isScanning ? "SCANNING" : "SCAN"))
                            .font(.system(size: 12.5, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                    }
                    FreqReadout(freq: store.currentFreqString, size: 60)
                    SMeter(level: store.meterSuppressed ? 0 : store.signalLevel,
                           active: !store.meterSuppressed, rawRSSI: store.rawRSSI)
                }
                .padding(.vertical, 20)

                Text("Scan list · \(scanList.count) channels")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(t.label2)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(scanList.enumerated()), id: \.element.id) { idx, mem in
                            let active = store.isScanning && idx == store.scanIndex
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(active ? t.accent : t.label3)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mem.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(active ? t.accent : t.label)
                                    Text(mem.group)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(active ? t.accent.opacity(0.7) : t.label2)
                                }
                                Spacer()
                                Text(mem.freqString)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(active ? t.accent : t.label2)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            .background(active ? t.accentSoft : Color.clear)
                            if idx < scanList.count - 1 {
                                Divider().padding(.leading, 34).background(t.sep)
                            }
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                if store.isScanning {
                    HStack(spacing: 12) {
                        if store.scanPaused {
                            Text("Signal found")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(t.green)
                        }
                        Button { store.stopScan() } label: {
                            Label("Stop scan", systemImage: "stop.fill")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .glassButtonStyle()
                        .controlSize(.large)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                } else {
                    Button { store.startScan() } label: {
                        Label("Start scan", systemImage: "barcode.viewfinder")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
                    .tint(t.accent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
    }
}
