import Foundation
import SwiftUI
import CoreLocation
import AVFoundation

// MARK: - Data Models

enum VoiceMode: String, CaseIterable {
    case vfo, scan
    var label: String {
        switch self {
        case .vfo:  return "VFO"
        case .scan: return "Scan"
        }
    }
}

struct Memory: Identifiable, Codable {
    var id = UUID()
    var name: String
    var group: String
    var freq: Float
    var offset: Float      // MHz, 0 = simplex
    var plTone: Float      // Hz, 0 = no tone
    var squelch: UInt8
    var isRepeater: Bool
    var notes: String = ""
    var scanEnabled: Bool = true
    var bandwidth: UInt8 = 0  // 0=wide 25kHz, 1=narrow 12.5kHz (RadioStore.bandwidth encoding)

    var freqString: String { String(format: "%.3f", freq) }
    var offsetString: String {
        if offset == 0 { return "Simplex" }
        return offset > 0 ? String(format: "+%.3f", offset) : String(format: "%.3f", offset)
    }
    var toneString: String { plTone == 0 ? "Off" : String(format: "PL %.1f", plTone) }
    var metaString: String {
        if isRepeater { return "Repeater · \(offsetString) · \(toneString)" }
        return "Simplex · \(notes.isEmpty ? "Simplex" : notes)"
    }

}

extension Memory {
    // Custom decode so memories saved before scanEnabled/bandwidth existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        freq = try c.decode(Float.self, forKey: .freq)
        offset = try c.decode(Float.self, forKey: .offset)
        plTone = try c.decode(Float.self, forKey: .plTone)
        squelch = try c.decode(UInt8.self, forKey: .squelch)
        isRepeater = try c.decode(Bool.self, forKey: .isRepeater)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        scanEnabled = try c.decodeIfPresent(Bool.self, forKey: .scanEnabled) ?? true
        bandwidth = try c.decodeIfPresent(UInt8.self, forKey: .bandwidth) ?? 0
    }
}

struct CaptionLine: Identifiable {
    let id = UUID()
    var callsign: String
    var time: String
    var text: String
    var active: Bool = false
    // SpeechManager segment feeding this line; nil for non-speech lines.
    var segmentID: Int? = nil
}

// MARK: - Radio Store

@Observable
class RadioStore {
    // ── Appearance
    var themeMode: AppThemeMode = .system {
        didSet { if !isInitializing { UserDefaults.standard.set(themeMode.rawValue, forKey: Self.themeModeKey) } }
    }
    // Resolved by ContentView (which has access to the system color scheme);
    // nested views read this via the `.theme` environment value.
    var theme: AppTheme = .dark

    // ── Radio
    // Desired/applied radio state. UI writes go through this controller's
    // setters (via helpers like sendRadioState); BLE is transport only.
    let radio: RadioModuleController
    let ble: BLEManager
    @ObservationIgnored private var isApplyingDeviceStateToUI = false

    // ── Location
    let locationManager = LocationManager()

    // ── Voice
    var voiceMode: VoiceMode = .vfo
    // Desired/applied radio squelch level (0 = monitor). Mirrored from
    // firmware state and sent through RadioModuleController on user changes.
    var squelch: UInt8 = 3 {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                UserDefaults.standard.set(Int(squelch), forKey: Self.squelchKey)
                ble.setRxAudioMuted(effectiveRxMuted)
            }
        }
    }
    // Desired VFO channel config; survives without a memory match. Seeded
    // from firmware-applied state on connect and from memory tunes.
    var vfoOffset: Float = 0       // MHz, 0 = simplex
    var vfoToneIndex: UInt8 = 0    // CTCSS index, 0 = off
    // Set while a beacon is out on its own simplex frequency: the applied
    // state then describes that channel, not the VFO, so it must not
    // overwrite vfoOffset/vfoToneIndex before the restore (#56).
    @ObservationIgnored private var isSimplexFrequencySwitchActive = false
    var captionsEnabled: Bool = false
    var isScanning: Bool = false
    var scanIndex: Int = 0
    var scanPaused: Bool = false
    @ObservationIgnored private var scanTimer: Timer?

    // ── Memories
    private static let memoriesKey = "savedMemories"
    private var isInitializing = true
    var memories: [Memory] = [] {
        didSet {
            if !isInitializing { saveMemories() }
        }
    }

    // ── APRS
    let aprs = APRSController()
    var aprsFilter: String = "All"
    var selectedEntry: APRSEntry? = nil
    var aprsSymbol: String = "[" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    // Position beaconing broadcasts callsign + location publicly and is
    // relayed to the internet by iGates, so it stays off until the user
    // accepts the disclosure in BeaconSettingsView. Never enabled by default.
    var aprsBeaconConsented: Bool = false {
        didSet {
            if !isInitializing {
                if !aprsBeaconConsented { aprsBeaconEnabled = false }
                saveAprsSettings()
            }
        }
    }
    var aprsBeaconEnabled: Bool = false {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                aprs.updateBeaconTimer()
            }
        }
    }
    var aprsBeaconIntervalMin: Int = 15 {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                aprs.updateBeaconTimer()
            }
        }
    }
    var aprsBeaconFrequency: String = "144.3900" {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                ble.setRxAudioMuted(effectiveRxMuted)
            }
        }
    }
    var aprsPositionApprox: Bool = false {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var silenceRxOnAprsFreq: Bool = false {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                ble.setRxAudioMuted(effectiveRxMuted)
            }
        }
    }

    // ── APRS notifications
    let notifications = NotificationManager()
    @ObservationIgnored let liveActivity = LiveActivityManager()
    var aprsNotify = APRSNotifySettings() {
        didSet { if !isInitializing { saveNotifySettings() } }
    }
    // Set when a notification's "Open Map" action fires; ContentView switches to
    // the Map tab and MapView centers on this entry, then clears it.
    var pendingMapFocusID: UUID? = nil

    // ── Captions
    var captionLines: [CaptionLine] = []
    let speechManager = SpeechManager()
    private(set) var captionsStatus: CaptionsStatus = .off
    @ObservationIgnored private var isRequestingSpeechAuth = false
    @ObservationIgnored private var captionRetryTask: Task<Void, Never>?
    // No audio reaches the recognizer in background (sample hook removed).
    @ObservationIgnored private var captionsSuspended = false
    private static let captionRetryDelay: Duration = .seconds(2)
    // Captions keep the segment open this long after squelch closes, so a
    // flickering squelch flag doesn't split sentences (see SquelchHangGate).
    @ObservationIgnored private var squelchGate = SquelchHangGate(hangTime: 1.5)
    @ObservationIgnored private var squelchCloseTask: Task<Void, Never>?
    @ObservationIgnored private var lastSquelchFlagChange: Date?

    // ── Settings
    var callsign: String = "" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var aprsSSID: String = "" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var txPower: String = "High" {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setHighPower(isHighPower)
            }
        }
    }
    var filterHighPass: Bool = true {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setFilters(highpass: filterHighPass, lowpass: filterLowPass)
            }
        }
    }
    var filterLowPass: Bool = false {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setFilters(highpass: filterHighPass, lowpass: filterLowPass)
            }
        }
    }
    var liveCaptions: Bool = true {
        didSet {
            guard !isInitializing, liveCaptions != oldValue else { return }
            refreshCaptionsStatus()
            requestCaptionsPermissionIfNeeded()
        }
    }
    var stickyPTT: Bool = false
    // Re-read on foreground: the user can only change it in Settings.
    var micPermission = MicPermission(AVAudioApplication.shared.recordPermission)
    var bandwidth: UInt8 = 0 {  // 0=wide 25kHz, 1=narrow 12.5kHz
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setBandwidth(bandwidth == 0 ? DRA818_25K : DRA818_12K5)
            }
        }
    }
    var captionLanguage: String = "English (US)"

    // ── Init
    init() {
        let radio = RadioModuleController()
        self.radio = radio
        self.ble = BLEManager(radio: radio)
        if let data = UserDefaults.standard.data(forKey: Self.memoriesKey),
           let decoded = try? JSONDecoder().decode([Memory].self, from: data) {
            memories = decoded
        } else {
            memories = [
                Memory(name: "Simplex", group: "Calling", freq: 146.52,
                       offset: 0, plTone: 0, squelch: 2,
                       isRepeater: false, notes: "National calling frequency")
            ]
        }
        loadAprsSettings()
        loadNotifySettings()
        if let raw = UserDefaults.standard.string(forKey: Self.themeModeKey),
           let mode = AppThemeMode(rawValue: raw) {
            themeMode = mode
        }
        if let s = UserDefaults.standard.object(forKey: Self.squelchKey) as? Int {
            squelch = UInt8(clamping: s)
        }
        isInitializing = false
        configureSpeechManager()
        // Location is only used by features the user opted into.
        if aprsBeaconEnabled || aprsNotify.distanceFilterMi != nil {
            locationManager.requestLocation()
        }

        aprs.store = self
        aprs.notifier = notifications
        notifications.configure()
        notifications.onReply = { [weak self] to, text in
            DispatchQueue.main.async { _ = self?.aprs.sendMessage(to: to, text: text) }
        }
        notifications.onMute = { [weak self] base, fromDemo in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.aprsNotify.mutedCallsigns.insert(base).inserted, fromDemo {
                    self.demoMutedCallsigns.insert(base)
                }
            }
        }
        notifications.onOpen = { [weak self] entryID, _, _ in
            DispatchQueue.main.async { self?.pendingMapFocusID = entryID }
        }
        ble.demoLocationProvider = { [weak self] in
            self?.locationManager.location?.coordinate
        }
        ble.onDemoSessionChanged = { [weak self] active in
            if active { self?.beginDemoSession() } else { self?.endDemoSession() }
        }
        ble.onAx25Frame = { [weak self] data in
            DispatchQueue.main.async { self?.aprs.handleAx25Frame(data) }
        }
        // Controller seeds desired state from firmware on HELLO; copy the
        // applied firmware config into the UI settings so the next user
        // action doesn't overwrite firmware state with stale UI defaults.
        ble.onTransportReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hydrateUISettingsFromAppliedState()
                self.ble.setRxAudioMuted(self.effectiveRxMuted)
                // Fire any message retries that came due while disconnected.
                self.aprs.processDueRetries()
            }
        }
        ble.onDeviceState = { [weak self] ds in
            guard let self else { return }
            self.meterGate.deviceState(txActive: ds.mode == 0, at: Date())
            self.refreshMeterGate()
            self.hydrateUISettingsFromAppliedState()
            self.ble.setRxAudioMuted(self.effectiveRxMuted)
        }
        aprs.updateBeaconTimer()
    }

    // MARK: - Demo session

    // Stations muted from demo notifications; unmuted when the demo ends.
    // Persisted so a launch after being killed mid-demo can undo them too.
    private static let demoMutesKey = "aprsDemoMutedCallsigns"
    @ObservationIgnored private var demoMutedCallsigns: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(demoMutedCallsigns), forKey: Self.demoMutesKey) }
    }

    // Demo traffic must leave nothing behind in real use (#62): history and
    // the message counter (APRSController), notification cooldowns and
    // banners (NotificationManager), mutes, and the Live Activity count.
    private func beginDemoSession() {
        demoMutedCallsigns = []
        aprs.beginDemoSession()
        notifications.beginDemoSession()
    }

    private func endDemoSession() {
        aprs.endDemoSession()
        notifications.endDemoSession()
        if !demoMutedCallsigns.isEmpty {
            aprsNotify.mutedCallsigns.subtract(demoMutedCallsigns)
            demoMutedCallsigns = []
        }
        liveActivity.end()
    }

    private static let themeModeKey = "themeMode"
    private static let aprsSettingsKey = "aprsSettings"
    private static let notifySettingsKey = "aprsNotifySettings"
    private static let squelchKey = "squelchLevel"

    private struct APRSSettings: Codable {
        var callsign: String
        var ssid: String
        var symbol: String
        var beaconEnabled: Bool
        var beaconIntervalMin: Int
        var beaconFrequency: String
        var positionApprox: Bool
        var silenceRxOnAprsFreq: Bool = false
        var beaconConsented: Bool?
    }

    private func loadAprsSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.aprsSettingsKey),
              let s = try? JSONDecoder().decode(APRSSettings.self, from: data) else { return }
        callsign = s.callsign
        aprsSSID = s.ssid
        aprsSymbol = s.symbol
        aprsBeaconConsented = s.beaconConsented ?? false
        // Settings saved before the consent gate existed may have beaconing on.
        aprsBeaconEnabled = s.beaconEnabled && aprsBeaconConsented
        aprsBeaconIntervalMin = s.beaconIntervalMin
        aprsBeaconFrequency = s.beaconFrequency
        aprsPositionApprox = s.positionApprox
        silenceRxOnAprsFreq = s.silenceRxOnAprsFreq
    }

    private func saveAprsSettings() {
        let s = APRSSettings(
            callsign: callsign, ssid: aprsSSID, symbol: aprsSymbol,
            beaconEnabled: aprsBeaconEnabled, beaconIntervalMin: aprsBeaconIntervalMin,
            beaconFrequency: aprsBeaconFrequency, positionApprox: aprsPositionApprox,
            silenceRxOnAprsFreq: silenceRxOnAprsFreq, beaconConsented: aprsBeaconConsented)
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.aprsSettingsKey)
    }

    private func loadNotifySettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.notifySettingsKey),
              var s = try? JSONDecoder().decode(APRSNotifySettings.self, from: data) else { return }
        // Undo mutes from a demo session that never ended (app killed), and
        // from builds before demo isolation.
        s.mutedCallsigns.subtract(DemoRadio.stationCallsigns)
        let demoMutes = UserDefaults.standard.stringArray(forKey: Self.demoMutesKey) ?? []
        s.mutedCallsigns.subtract(demoMutes)
        UserDefaults.standard.removeObject(forKey: Self.demoMutesKey)
        aprsNotify = s
    }

    private func saveNotifySettings() {
        guard let data = try? JSONEncoder().encode(aprsNotify) else { return }
        UserDefaults.standard.set(data, forKey: Self.notifySettingsKey)
    }

    private func hydrateUISettingsFromAppliedState() {
        guard let ds = radio.deviceState else { return }
        isApplyingDeviceStateToUI = true
        defer { isApplyingDeviceStateToUI = false }
        squelch = ds.squelch
        bandwidth = ds.bw == DRA818_25K ? 0 : 1
        txPower = (!radio.hasHighLowPowerSwitch || (ds.flags & HOST_STATE_HIGH_POWER) != 0) ? "High" : "Low"
        // Firmware DSP stop filters (see RadioModuleController.setFilters):
        // FILTER_LOW is the high-pass, FILTER_HIGH the low-pass. Both sit after
        // the AFSK/squelch taps, so they only shape voice audio.
        filterHighPass = (ds.flags & HOST_STATE_FILTER_LOW) != 0
        filterLowPass = (ds.flags & HOST_STATE_FILTER_HIGH) != 0
        if let vfo = Self.appliedVfoConfig(ds, simplexSwitchActive: isSimplexFrequencySwitchActive) {
            vfoOffset = vfo.offset
            vfoToneIndex = vfo.toneIndex
        }
    }

    // VFO offset/tone implied by an applied state, or nil when it belongs
    // to a temporary simplex frequency switch and must be ignored.
    nonisolated static func appliedVfoConfig(
        _ ds: DeviceStateFrame, simplexSwitchActive: Bool
    ) -> (offset: Float, toneIndex: UInt8)? {
        guard !simplexSwitchActive else { return nil }
        return (ds.freqTx - ds.freqRx, ds.ctcssTx)
    }

    // Retunes simplex (no offset/tone) to `freq` for `body`, then restores
    // the original VFO channel with its offset and tone intact.
    func withSimplexFrequency(_ freq: Float, _ body: () async -> Void) async {
        let originalFreq = currentFreq
        isSimplexFrequencySwitchActive = true
        sendRadioState(freq: freq, simplexOverride: true)
        await body()
        isSimplexFrequencySwitchActive = false
        sendRadioState(freq: originalFreq)
    }

    private func configureSpeechManager() {
        speechManager.configure(language: captionLanguage)

        speechManager.onPartialResult = { [weak self] segmentID, text in
            guard let self else { return }
            if let idx = self.captionLines.lastIndex(where: { $0.segmentID == segmentID }) {
                self.captionLines[idx].text = text
            }
        }

        speechManager.onSegmentFinalized = { [weak self] segmentID in
            guard let self else { return }
            for i in self.captionLines.indices where self.captionLines[i].segmentID == segmentID {
                self.captionLines[i].active = false
            }
            self.captionLines.removeAll { $0.text.isEmpty && !$0.active }
            if self.captionLines.count > 100 {
                self.captionLines.removeFirst(self.captionLines.count - 100)
            }
        }

        // The analyzer session died while a continuous signal may still
        // hold squelch open; no squelch transition will come, so retry on
        // our own.
        speechManager.onSessionFailed = { [weak self] in
            self?.scheduleCaptionRetry()
        }

        // Language support is only known after an async check.
        speechManager.onAvailabilityChanged = { [weak self] in
            self?.refreshCaptionsStatus()
        }

        refreshCaptionsStatus()
    }

    // Re-derives captionsStatus from the toggle, permission, and on-device
    // support; starts or stops recognition to match. Call when any input
    // may have changed (toggle, permission prompt, returning from Settings).
    func refreshCaptionsStatus() {
        let status = CaptionsStatus.resolve(
            enabled: liveCaptions,
            authorization: speechManager.authorizationStatus,
            supportsOnDevice: speechManager.supportsOnDeviceRecognition)
        if status != captionsStatus { captionsStatus = status }
        if captionsStatus == .listening, !captionsSuspended {
            // Load the model before the first transmission arrives.
            speechManager.startSession()
            startCaptionsIfReceiving()
        } else {
            stopCaptions()
            speechManager.stopSession()
        }
    }

    // Asks for speech recognition at point of intent (Captions sheet opened
    // or toggle turned on), never at launch.
    func requestCaptionsPermissionIfNeeded() {
        guard captionsStatus == .needsPermission, !isRequestingSpeechAuth else { return }
        isRequestingSpeechAuth = true
        speechManager.requestAuthorization { [weak self] _ in
            guard let self else { return }
            self.isRequestingSpeechAuth = false
            self.refreshCaptionsStatus()
        }
    }

    private func startCaptionsIfReceiving() {
        guard captionsStatus == .listening, !captionsSuspended, !isSquelched,
              !speechManager.isSegmentActive else { return }
        captionRetryTask?.cancel()
        if let segmentID = speechManager.startSegment() {
            // Segments can start outside a squelch transition (foreground,
            // permission granted); make sure the gate knows we're open.
            _ = squelchGate.update(squelched: false, now: Date())
            appendNewCaptionLine(segmentID: segmentID)
        } else {
            scheduleCaptionRetry()
        }
    }

    private func scheduleCaptionRetry() {
        captionRetryTask?.cancel()
        guard captionsStatus == .listening, !captionsSuspended, !isSquelched else { return }
        captionRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.captionRetryDelay)
            guard !Task.isCancelled else { return }
            self?.startCaptionsIfReceiving()
        }
    }

    private func stopCaptions() {
        captionRetryTask?.cancel()
        captionRetryTask = nil
        squelchCloseTask?.cancel()
        squelchCloseTask = nil
        squelchGate.reset()
        speechManager.endSegment()
    }

    private func appendNewCaptionLine(segmentID: Int) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        captionLines.append(CaptionLine(
            callsign: "RX",
            time: formatter.string(from: Date()),
            text: "",
            active: true,
            segmentID: segmentID
        ))
    }

    // ── Derived helpers
    var isHighPower: Bool { txPower == "High" }

    var currentFreq: Float {
        ble.deviceState?.freqRx ?? 146.52
    }

    var currentFreqString: String {
        String(format: "%.3f", currentFreq)
    }

    var signalLevel: Int {
        guard let ds = ble.deviceState, ds.rssi > 0 else { return 0 }
        let result = 9.73 * log(0.0297 * Double(ds.rssi)) - 1.88
        return max(1, min(9, Int(result.rounded())))
    }

    var rawRSSI: UInt8 {
        ble.deviceState?.rssi ?? 0
    }

    // True while the S-meter must read zero: PTT pressed (before the
    // firmware echoes TX), TX applied, an APRS frame queued for the
    // firmware to key, or the short hold after any of those ends.
    private(set) var meterSuppressed = false
    @ObservationIgnored private var meterGate = TxMeterGate()
    @ObservationIgnored private var meterGateExpiry: Task<Void, Never>?

    // APRSController calls this as it hands a frame to the firmware.
    func notePacketTx() {
        meterGate.packetQueued(at: Date())
        refreshMeterGate()
    }

    private func refreshMeterGate() {
        let now = Date()
        let suppressed = meterGate.suppressed(at: now)
        if suppressed != meterSuppressed { meterSuppressed = suppressed }
        meterGateExpiry?.cancel()
        guard let next = meterGate.nextExpiry(after: now) else { return }
        meterGateExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.refreshMeterGate()
        }
    }

    // Applied TX offset from firmware state; preserves split TX/RX config
    // that has no matching memory.
    var currentTxOffset: Float {
        guard let ds = ble.deviceState else { return 0 }
        return ds.freqTx - ds.freqRx
    }

    // Where PTT would key (sendRadioState: VFO freq + offset) is outside the
    // amateur band, so the controller withholds TX_ALLOWED and PTT. Built
    // from observed state so the PTT button tracks it; false before HELLO.
    var isTxOutOfBand: Bool {
        guard let hello = ble.hello else { return false }
        return !BandPlan.canTransmit(
            onFrequency: currentFreq + vfoOffset,
            bandwidth: bandwidth == 0 ? DRA818_25K : DRA818_12K5,
            rfModuleType: hello.rfModuleType)
    }

    // What a voice PTT press does right now. Demo Radio skips the mic check:
    // it never captures audio (BLEManager only starts the mic for a real
    // link), so prompting there would ask for access the app doesn't use.
    var voicePTTGate: PTTGate.Decision {
        PTTGate.decide(outOfBand: isTxOutOfBand, mic: micPermission, micRequired: !ble.isDemo)
    }

    var currentOffsetString: String {
        let offset = currentTxOffset
        if abs(offset) < 0.0005 { return "Simplex" }
        return offset > 0 ? String(format: "+%.3f", offset) : String(format: "%.3f", offset)
    }

    // Applied TX tone from firmware state.
    var currentToneString: String {
        guard let ds = ble.deviceState, let hz = ctcssToneHz(for: ds.ctcssTx) else { return "Off" }
        return String(format: "PL %.1f", hz)
    }

    var rxMode: RadioRxState {
        guard let ds = ble.deviceState else { return .idle }
        switch ds.mode {
        case 0: return .tx
        case 1: return isSquelched ? .idle : .rx
        default: return .idle
        }
    }

    func memory(for freq: Float) -> Memory? {
        memories.first { abs($0.freq - freq) < 0.001 }
    }

    var activeMemoryId: UUID? {
        memory(for: currentFreq)?.id
    }

    var isSquelched: Bool {
        guard let ds = ble.deviceState else { return true }
        return (ds.flags & DEVICE_STATE_SQUELCHED) != 0
    }

    var isTunedToAprsFreq: Bool {
        guard aprsBeaconFrequency != "Current",
              let aprsFreq = Float(aprsBeaconFrequency) else { return false }
        return abs(currentFreq - aprsFreq) < 0.0005
    }

    // Standard regional APRS frequencies (mirrors the Settings picker).
    static let knownAprsFrequencies: [Float] = [144.390, 144.575, 144.640, 144.660, 144.800, 145.175, 145.825]

    // APRS counts as active when tuned to the configured APRS frequency or any
    // standard one — covers the "Current" beacon setting too.
    var isAprsActive: Bool {
        isTunedToAprsFreq || Self.knownAprsFrequencies.contains { abs(currentFreq - $0) < 0.0005 }
    }

    // The Live Activity only shows APRS traffic, so it exists only while the
    // radio is connected, the user has it enabled, and we're on an APRS freq.
    // start()/end() are idempotent, so this is safe to call on any change.
    // Mid-reconnect (scanning/connecting, no device state yet) leaves it as-is.
    func syncLiveActivity() {
        let state = ble.bleState
        if state == .idle || !aprsNotify.liveActivityEnabled {
            liveActivity.end()
        } else if state == .ready, ble.deviceState != nil {
            if isAprsActive {
                liveActivity.start(enabled: true)
            } else {
                liveActivity.end()
            }
        }
    }

    var isOnAprsFreq: Bool {
        silenceRxOnAprsFreq && isTunedToAprsFreq
    }

    var effectiveRxMuted: Bool {
        isSquelched || isOnAprsFreq
    }

    func checkSquelchTransition() {
        let now = Date()
        let squelched = isSquelched
        let action = squelchGate.update(squelched: squelched, now: now)
        // Diagnostic: a short open/closed interval here means the firmware
        // squelch flag is flapping.
        let sinceLast = lastSquelchFlagChange.map { String(format: "%.0f ms", now.timeIntervalSince($0) * 1000) } ?? "n/a"
        lastSquelchFlagChange = now
        print("[Captions] squelch flag \(squelched ? "closed" : "open") after \(sinceLast) -> \(action) (flaps absorbed: \(squelchGate.absorbedFlaps))")

        switch action {
        case .scheduleClose(let after):
            squelchCloseTask?.cancel()
            squelchCloseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(after))
                guard !Task.isCancelled, let self,
                      self.squelchGate.closeTimerFired(now: Date()) else { return }
                self.stopCaptions()
            }
        case .cancelClose:
            squelchCloseTask?.cancel()
            squelchCloseTask = nil
            // The recognizer may have ended the segment during the hang.
            startCaptionsIfReceiving()
        case .open, .none:
            // Level-based so it stays correct after segments started
            // outside a transition; no-ops when already in the right state.
            if !squelched {
                startCaptionsIfReceiving()
            } else if !squelchGate.isHanging {
                stopCaptions()
            }
        }
    }

    func setupAudioSampleHook() {
        ble.setAudioSampleHook { [weak self] samples, count in
            guard let self, self.liveCaptions else { return }
            self.speechManager.feedSamples(samples, count: count)
        }
    }

    // Backgrounding keeps audio + BLE running; only UI-side work pauses
    // (speech recognition burns CPU and is unreliable in background).
    func enterBackground() {
        ble.setAudioSampleHook(nil)
        captionsSuspended = true
        stopCaptions()
        speechManager.stopSession()
        // Ensure the Live Activity matches current state — covers the case
        // where the link was already up before the activity could start. It
        // then renders on the Lock Screen.
        syncLiveActivity()
    }

    func enterForeground() {
        setupAudioSampleHook()
        ble.recoverAudioIfNeeded()
        captionsSuspended = false
        // Settings may have changed location access while we were away.
        locationManager.refresh()
        // Speech permission may have changed in Settings while away; also
        // resumes captions if a signal is still being received.
        refreshCaptionsStatus()
        refreshMicPermission()
        // Settings may have changed location access while we were away.
        locationManager.refresh()
    }

    func refreshMicPermission() {
        micPermission = MicPermission(AVAudioApplication.shared.recordPermission)
    }

    // Prompts for the mic. Never keys: the press that triggered it is spent
    // on the system alert, so the next press transmits.
    func requestMicPermission() {
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            refreshMicPermission()
        }
    }

    var scanList: [Memory] { memories.filter(\.scanEnabled) }

    func startScan() {
        guard !scanList.isEmpty else { return }
        isScanning = true
        scanPaused = false
        scanIndex = 0
        tuneToScanIndex()
        scheduleScanTick()
    }

    func stopScan() {
        isScanning = false
        scanPaused = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func scheduleScanTick() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.scanTick() }
        }
    }

    private func scanTick() {
        let list = scanList
        guard isScanning, !list.isEmpty else { return }

        if !isSquelched {
            scanPaused = true
            return
        }

        if scanPaused {
            scanPaused = false
        }

        scanIndex = (scanIndex + 1) % list.count
        tuneToScanIndex()
    }

    private func tuneToScanIndex() {
        let list = scanList
        guard scanIndex < list.count else { return }
        applyMemory(list[scanIndex])
    }

    func updateMemory(_ memory: Memory) {
        guard let idx = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[idx] = memory
    }

    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
    }

    // User-intent helper: pushes the current UI settings + VFO channel
    // config (and optional freq/PTT change) into the controller's desired
    // state as one batch. The controller decides if a DesiredState frame
    // actually goes out. Offset and tone come from the VFO fields — tuning
    // a memory seeds them first via applyMemory.
    // simplexOverride: transmit on the RX frequency with no tone, without
    // touching the VFO fields (APRS frequency-switch beacons are simplex).
    // TX_ALLOWED follows the resulting TX freq/bandwidth inside the
    // controller, which also drops `ptt` when that's out of band.
    func sendRadioState(freq: Float? = nil, ptt: Bool = false, simplexOverride: Bool = false) {
        let rxFreq = freq ?? currentFreq
        radio.beginUpdate()
        radio.setTxFrequency(rxFreq + (simplexOverride ? 0 : vfoOffset))
        radio.setRxFrequency(rxFreq)
        radio.setSquelch(squelch)
        radio.setBandwidth(bandwidth == 0 ? DRA818_25K : DRA818_12K5)
        radio.setTxTone(simplexOverride ? 0 : vfoToneIndex)
        radio.setFilters(highpass: filterHighPass, lowpass: filterLowPass)
        radio.setHighPower(isHighPower)
        if ptt { radio.pttDown() } else { radio.pttUp() }
        radio.endUpdate()
        meterGate.setPTT(ptt, at: Date())
        refreshMeterGate()
    }

    // Batched so the bandwidth didSet and the channel push go out as one
    // DesiredState; the controller re-derives TX_ALLOWED for the new margin.
    func applyMemory(_ mem: Memory) {
        radio.beginUpdate()
        vfoOffset = mem.offset
        vfoToneIndex = ctcssIndex(for: mem.plTone)
        bandwidth = mem.bandwidth
        sendRadioState(freq: mem.freq)
        radio.endUpdate()
    }

    // Pill-editor entry point: one desired-state push for both fields.
    func setVfoConfig(offset: Float, toneIndex: UInt8) {
        vfoOffset = offset
        vfoToneIndex = toneIndex
        sendRadioState()
    }

    private func saveMemories() {
        let mems = memories
        DispatchQueue.global(qos: .background).async {
            guard let data = try? JSONEncoder().encode(mems) else { return }
            UserDefaults.standard.set(data, forKey: Self.memoriesKey)
        }
    }
}

enum RadioRxState {
    case idle, rx, tx
    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .rx:   return "RECEIVING"
        case .tx:   return "TRANSMIT"
        }
    }
}

