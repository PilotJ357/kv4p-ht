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
    // Raw space the tab gets; the layout is derived so text size can factor in.
    @State private var stageSize: CGSize?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stageLayout: StageLayout {
        stageSize.map { StageLayout(size: $0, dynamicType: dynamicTypeSize) } ?? .regular
    }

    // The stage is fixed-height with no scrolling (PTT is a hold gesture, so it
    // can't live in a ScrollView), so its text stops growing before it would
    // push the PTT button under the tab bar.
    private var typeCap: DynamicTypeSize {
        switch stageLayout {
        case .wide:    .xxxLarge
        case .regular: .xxLarge
        case .compact: .xLarge
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceStrip(
                connected: store.ble.bleState == .ready,
                demo: store.ble.isDemo,
                action: { showDevicePicker = true }
            )
            .dynamicTypeSize(...typeCap)

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
                            .dynamicTypeSize(...typeCap)
            case .scan: ScanBody(store: store)
            }

            // Wide stage centers itself in the leftover height.
            if stageLayout != .wide {
                Spacer(minLength: 0)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stageSize = $0 }
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

    init(size: CGSize, dynamicType: DynamicTypeSize = .large) {
        // The 650pt breakpoint is calibrated at the default text size; each step
        // up eats roughly 14pt of stage height, so count it against the space.
        let sizes = DynamicTypeSize.allCases
        let steps = max(0, (sizes.firstIndex(of: min(dynamicType, .xxLarge)) ?? 0)
                         - (sizes.firstIndex(of: .large) ?? 0))
        if size.width >= 700 { self = .wide }
        else if size.height - CGFloat(steps) * 14 < 650 { self = .compact }
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
        // Band from HELLO (0 = VHF, else UHF); empty until the module reports.
        let band = store.ble.hello.map { $0.rfModuleType == 0 ? "VHF" : "UHF" } ?? ""
        RadioStage(
            store:        store,
            channelName:  matched?.name ?? store.currentFreqString,
            channelDesc:  matched?.notes ?? "",
            freq:         store.currentFreqString,
            offset:       store.currentOffsetString,
            tone:         store.currentToneString,
            modeLabel:    band,
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
    // Band ("VHF"/"UHF"); empty until the module reports.
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

    // Band chip doubles as the TX time-out countdown in its last seconds.
    private var chipLabel: String? {
        if let remaining = store.txTimeoutRemaining { return "TX ends in \(remaining)s" }
        return modeLabel.isEmpty ? nil : modeLabel
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
                        .padding(.bottom, compact ? 8 : 10)
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
                .presentationDetents([.height(470)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showOffsetTone) {
            OffsetToneSheet(store: store)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
        }
    }

    // Band chip, frequency, channel name, S-meter.
    private var readout: some View {
        VStack(spacing: 0) {
            // Always laid out (placeholder text, hidden) so the stage doesn't
            // jump when the band arrives or the countdown comes and goes.
            HStack(spacing: 6) {
                Circle()
                    .fill(txApplied ? t.red : t.accent)
                    .frame(width: 6, height: 6)
                Text(chipLabel ?? "VHF")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .tracking(1)
                    .foregroundStyle(t.label)
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(t.fill)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(chipLabel == nil ? 0 : 1)
            .accessibilityHidden(chipLabel == nil)
            .padding(.top, compact ? 6 : 10)

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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(t.label)
                Text(channelDesc)
                    .font(.footnote)
                    .foregroundStyle(t.label2)
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.top, 2)

            HStack(spacing: 14) {
                SMeter(level: store.meterSuppressed ? 0 : store.signalLevel,
                       active: !store.meterSuppressed, rawRSSI: store.rawRSSI)
                RxBadge(state: rxState)
            }
            .padding(.top, 6)
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
        .padding(.top, 8)
        .padding(.bottom, compact ? 6 : 8)
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
        VStack(spacing: compact ? 6 : 8) {
            SliderRow(title: "Volume", icon: "speaker.wave.2.fill", tint: t.accent) {
                SystemVolumeView(tint: UIColor(t.accent))
            } trailing: {
                RoutePicker(tint: UIColor(t.label2), activeTint: UIColor(t.accent))
                    .frame(width: 24)
            }
            // Amber and a dial icon set it apart from Volume (in Night the two
            // tints are close, so the icon carries the difference).
            SliderRow(title: "Squelch", icon: "dial.medium.fill", tint: t.amber) {
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

// MARK: - Offset / Tone editor

private struct OffsetToneSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

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

    private static let presets: [Float] = [0.600, 5.000]

    init(store: RadioStore) {
        self.store = store
        // Seed from desired VFO state, not applied — this sheet edits intent.
        let off = store.vfoOffset
        _direction = State(initialValue: abs(off) < 0.0005 ? .simplex : (off > 0 ? .plus : .minus))
        _magnitudeText = State(initialValue: String(format: "%.3f", abs(off) < 0.0005 ? 0.600 : abs(off)))
        _toneIndex = State(initialValue: Int(store.vfoToneIndex))
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
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("Channel Config")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(t.label)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                // Offset
                Text("TX OFFSET")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(t.label2)
                    .padding(.horizontal, 24)
                Picker("Direction", selection: $direction) {
                    ForEach(Direction.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if direction != .simplex {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.self) { preset in
                            Button {
                                magnitudeText = String(format: "%.3f", preset)
                            } label: {
                                Text(String(format: "%.3f", preset))
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(magnitude == preset ? .white : t.label)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(magnitude == preset ? t.accent : t.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("MHz", text: $magnitudeText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(t.label)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(t.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .frame(width: 90)
                        Text("MHz")
                            .font(.system(size: 13))
                            .foregroundStyle(t.label2)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }

                // Tone
                Text("TX TONE (CTCSS)")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(t.label2)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                Picker("Tone", selection: $toneIndex) {
                    Text("Off").tag(0)
                    ForEach(1...CTCSS_TONES.count, id: \.self) { idx in
                        Text(String(format: "%.1f Hz", CTCSS_TONES[idx - 1])).tag(idx)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 110)
                .clipped()
                .padding(.horizontal, 20)

                Spacer(minLength: 0)

                Button(action: apply) {
                    Text("APPLY")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButtonStyle()
                .controlSize(.large)
                .tint(t.accent)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
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
    // Outer ring; the face and glyph scale with it.
    var diameter: CGFloat = 168

    private var scale: CGFloat { diameter / 168 }
    private var faceSize: CGFloat { diameter * 0.86 }
    private var inert: Bool { rxOnly || noMic }
    private var onAir: Bool { isDown && !inert }
    // Idle is a tinted disc and ON AIR a solid red one. Separating them by fill
    // rather than hue keeps the states distinct in Night, where accent == red.
    private var solidFill: Color { inert ? t.fill : (onAir ? t.red : t.accentSoft) }
    private var glassTint: Color { inert ? t.fill : (onAir ? t.red : t.accent.opacity(0.35)) }
    private var ringColor: Color { inert ? t.hairline : (onAir ? t.red : t.accent.opacity(0.4)) }
    // Ink on the solid ON AIR face; Night stays dark on red so no white
    // pixels break dark adaptation.
    private var onFill: Color { t.mode == .night ? t.bg : Color.white }
    private var glyphColor: Color { inert ? t.label2 : (onAir ? onFill : t.accent) }
    private var captionColor: Color { inert ? t.label2 : (onAir ? onFill : t.label) }
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

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(ringColor, lineWidth: onAir ? 2 : 1.5)
                .frame(width: diameter, height: diameter)
            face
                .shadow(color: onAir ? t.red.opacity(0.45) : .clear, radius: 18)
        }
        // The gap between ring and face is part of the button.
        .contentShape(Circle())
        .scaleEffect(onAir && !reduceMotion ? 0.97 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: onAir)
        .accessibilityLabel(a11yLabel)
    }

    private var content: some View {
        VStack(spacing: 4) {
            Image(systemName: inert ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 36 * scale, weight: .medium))
                .foregroundStyle(glyphColor)
            Text(stateLabel)
                .font(.caption2.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: faceSize, height: faceSize)
    }

    @ViewBuilder private var face: some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(glassTint), in: .circle)
        } else {
            content.background(solidFill, in: .circle)
        }
    }
}

// MARK: - Slider row

// Named slider: icon, caption and trailing accessory (route picker, level)
// on one line, the slider full width underneath. The tint colors the icon
// and the track so each row reads as its own control.
private struct SliderRow<Content: View, Trailing: View>: View {
    @Environment(\.theme) var t
    var title: String
    var icon: String
    var tint: Color
    @ViewBuilder var slider: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(t.label2)
                    .accessibilityHidden(true)
                Spacer()
                trailing()
                    .frame(height: 24)
            }
            slider()
                .tint(tint)
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
            // Shrinks to fit rather than touching the screen edges; the unit
            // keeps its size.
            Text(freq)
                .font(.system(size: size, weight: .bold, design: .default).monospacedDigit())
                .tracking(-1.5)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("MHz")
                .font(.system(size: size * 0.27, weight: .semibold))
                .foregroundStyle(t.label2)
                .lineLimit(1)
                .fixedSize()
        }
        // Digits have no ascenders or descenders, so the line box carries about
        // 18pt of dead space top and bottom at 74pt; trim most of it.
        .frame(height: size * 0.94)
        .padding(.horizontal, 20)
    }
}

// MARK: - Frequency numpad

private struct FreqNumpad: View {
    @Environment(\.theme) var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    var currentFreq: String

    @State private var digits: String
    @State private var hasEdited = false
    @State private var rangeError: String?

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
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                // Display
                VStack(spacing: 2) {
                    Text(displayText)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(rangeError == nil ? t.label : t.red)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(rangeError ?? "MHz")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(rangeError == nil ? t.label2 : t.red)
                }
                .padding(.top, 28)
                .padding(.bottom, 28)

                // Numpad
                VStack(spacing: 10) {
                    numpadRow(["1","2","3"])
                    numpadRow(["4","5","6"])
                    numpadRow(["7","8","9"])
                    numpadRow([".","0","⌫"])
                }
                .padding(.horizontal, 28)

                // Set
                Button(action: commit) {
                    Text("SET")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButtonStyle()
                .controlSize(.large)
                .tint(t.accent)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func numpadRow(_ keys: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button {
                    tap(key)
                } label: {
                    Text(key)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(key == "⌫" ? t.label2 : t.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(t.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
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

// MARK: - Scan screen

private struct ScanBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 48

    private var scanList: [Memory] { store.scanList }

    var body: some View {
        if scanList.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: emptyIconSize, weight: .thin))
                    .foregroundStyle(t.label3)
                Text("No scan channels")
                    .font(.headline)
                    .foregroundStyle(t.label)
                Text("Add memories to build a scan list.")
                    .font(.subheadline)
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                        Text(store.scanPaused ? "PAUSED" : (store.isScanning ? "SCANNING" : "SCAN"))
                            .font(.caption.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                    }
                    FreqReadout(freq: store.currentFreqString, size: 60)
                    SMeter(level: store.meterSuppressed ? 0 : store.signalLevel,
                           active: !store.meterSuppressed, rawRSSI: store.rawRSSI)
                }
                .padding(.vertical, 20)

                Text("Scan list · \(scanList.count) channels")
                    .font(.caption.weight(.medium))
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
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(active ? t.accent : t.label)
                                    Text(mem.group)
                                        .font(.caption)
                                        .foregroundStyle(active ? t.accent.opacity(0.7) : t.label2)
                                }
                                Spacer()
                                Text(mem.freqString)
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
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
                                .font(.footnote.weight(.semibold))
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
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(t.label)
                    Text("Live transcription · on-device")
                        .font(.system(size: 13))
                        .foregroundStyle(t.label2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(isListening ? t.red : t.label3)
                        .frame(width: 7, height: 7)
                        .shadow(color: isListening ? t.red : .clear, radius: 4)
                    Text(isListening ? "LIVE" : "OFF")
                        .font(.system(size: 12, weight: .heavy))
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
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(line.active ? t.green : t.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(line.active ? t.greenSoft : t.accentSoft)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if !line.active {
                                    Text(line.time)
                                        .font(.system(size: 11.5, design: .monospaced))
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
                                    .font(.system(size: 16.5))
                                    .foregroundStyle(t.label2)
                                    .italic()
                                    .padding(.horizontal, 13)
                            } else {
                                Text(line.text)
                                    .font(.system(size: 16.5))
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
                    .font(.system(size: 14))
                    .foregroundStyle(t.label3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TranscriptLogView(store: store)
                } label: {
                    Label("Transcript log", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .environment(\.theme, store.theme)
        // Opening captions is the point of intent for the speech prompt.
        .onAppear { store.requestCaptionsPermissionIfNeeded() }
    }

    // Why captions aren't running, plus the one action that fixes it.
    private func statusPanel(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 14))
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(t.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(t.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
