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

    // Applied state (firmware DeviceState) drives the badge, frequency color,
    // and S-meter (RSSI in RX, TX audio level in TX); local request state only
    // drives the PTT button visual.
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
                SMeter(level: store.signalLevel, tx: store.rxMode == .tx, rawRSSI: store.rawRSSI)
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
        // PTT flips the session category (.playback ↔ .playAndRecord), and
        // the slider tracks the other category's volume mid-flip, so the
        // thumb jumped on every key-up/key-down. Show a snapshot while TX is
        // up and for a settle window after returning to RX. The live slider
        // is hidden underneath: the snapshot is transparent off the track, so
        // a moving live thumb would show through as a second thumb.
        private static let settle: TimeInterval = 0.8
        private var freeze: UIView?
        private var unfreeze: DispatchWorkItem?
        private var modeObserver: NSObjectProtocol?

        override init(frame: CGRect) {
            super.init(frame: frame)
            modeObserver = NotificationCenter.default.addObserver(
                forName: .audioSessionModeWillChange, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.sessionModeWillChange(tx: note.userInfo?["tx"] as? Bool ?? false)
                }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
        }

        private func sessionModeWillChange(tx: Bool) {
            unfreeze?.cancel()
            unfreeze = nil
            if tx {
                guard freeze == nil, window != nil,
                      let snap = snapshotView(afterScreenUpdates: false) else { return }
                snap.frame = bounds
                snap.isUserInteractionEnabled = false
                addSubview(snap)
                freeze = snap
                hideLiveSubviews(true)
            } else if freeze != nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.freeze?.removeFromSuperview()
                    self?.freeze = nil
                    self?.hideLiveSubviews(false)
                }
                unfreeze = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            for case let button as UIButton in subviews { button.isHidden = true }
            if let freeze {
                freeze.frame = bounds
                bringSubviewToFront(freeze)
                hideLiveSubviews(true)
            }
        }

        // MPVolumeView can re-add its slider on a route change mid-freeze,
        // so a subview added while frozen starts hidden too.
        override func didAddSubview(_ subview: UIView) {
            super.didAddSubview(subview)
            if freeze != nil, subview !== freeze { subview.alpha = 0 }
        }

        private func hideLiveSubviews(_ hidden: Bool) {
            for view in subviews where view !== freeze {
                view.alpha = hidden ? 0 : 1
            }
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
                    SMeter(level: store.signalLevel, tx: store.rxMode == .tx, rawRSSI: store.rawRSSI)
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
