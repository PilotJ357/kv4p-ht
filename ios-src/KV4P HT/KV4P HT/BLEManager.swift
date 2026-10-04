import Foundation
@preconcurrency import CoreBluetooth
import CoreLocation

private let BLE_KISS_SERVICE_UUID = CBUUID(string: "00000001-ba2a-46c9-ae49-01b0961f68bb")
private let BLE_KISS_TX_CHAR_UUID = CBUUID(string: "00000003-ba2a-46c9-ae49-01b0961f68bb")
private let BLE_KISS_RX_CHAR_UUID = CBUUID(string: "00000002-ba2a-46c9-ae49-01b0961f68bb")

enum BLEState {
    case idle, scanning, connecting, connected, ready
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
}

@Observable
class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var bleState: BLEState = .idle
    var discoveredDevices: [DiscoveredDevice] = []
    var hello: HelloFrame?
    var deviceState: DeviceStateFrame?
    @ObservationIgnored var audioFrameCount: Int = 0
    var logEntries: [String] = []
    var bleUnavailable = false
    var audioPlaying = false
    var audioAvailable = false
    // True while the simulated demo radio stands in for hardware.
    var isDemo = false
    // Read on main when demo mode starts; demo stations cluster around it.
    @ObservationIgnored var demoLocationProvider: (() -> CLLocationCoordinate2D?)?
    // Called on bleQueue with decoded AX.25 frame bytes (no FCS).
    @ObservationIgnored var onAx25Frame: ((Data) -> Void)?
    // Called on bleQueue after HELLO seeding + transport ready, so the app can
    // re-apply user-level desired state (e.g. squelch) on each (re)connect.
    @ObservationIgnored var onTransportReady: (() -> Void)?
    // Fired (on main) after each device-state frame is applied, so the host can
    // re-evaluate the RSSI-based software squelch.
    @ObservationIgnored var onDeviceState: ((DeviceStateFrame) -> Void)?
    // Fired on main when demo mode starts (true) — before any demo frame is
    // delivered — and ends (false), after the last one.
    @ObservationIgnored var onDemoSessionChanged: ((Bool) -> Void)?

    private let bleQueue = DispatchQueue(label: "kv4p-ht.ble", qos: .userInitiated)
    private let audio = AudioManager()
    // Radio state lives in the controller; this class is transport only.
    @ObservationIgnored private let radio: RadioModuleController
    // Confined to bleQueue.
    @ObservationIgnored private let gate = FlowControlGate()

    func setAudioSampleHook(_ handler: (([Float], Int) -> Void)?) {
        audio.onDecodedSamples = handler
    }

    /// Open/close the phone-side software squelch gate on RX playback.
    func setRxAudioMuted(_ on: Bool) {
        audio.setRxMuted(on)
    }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var parser = KissParser()
    @ObservationIgnored private var pendingLogEntries: [String] = []
    @ObservationIgnored private var logFlushScheduled = false
    @ObservationIgnored private var transmitting = false
    @ObservationIgnored private var userInitiatedDisconnect = false
    // Confined to bleQueue. Non-nil while demo mode is active.
    @ObservationIgnored private var demo: DemoRadio?
    // Confined to bleQueue. Link-setup watchdog: firmware sends HELLO only on
    // the CCCD subscribe edge, so if iOS reuses a link the firmware never saw
    // drop (CCCD still enabled), no HELLO arrives and setup hangs. Bumping
    // setupToken cancels the pending watchdog.
    @ObservationIgnored private var helloReceived = false
    @ObservationIgnored private var resubscribeAttempted = false
    @ObservationIgnored private var setupToken = 0

    init(radio: RadioModuleController) {
        self.radio = radio
        super.init()
        gate.onSend = { [weak self] frame in self?.writeRaw(frame) }
        central = CBCentralManager(delegate: self, queue: bleQueue)
        audioAvailable = audio.isAvailable  // nonisolated — no await needed
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        onMain {
            self.discoveredDevices = []
            self.bleState = .scanning
        }
        central.scanForPeripherals(withServices: [BLE_KISS_SERVICE_UUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("Scanning for KV4P BLE radios...")
    }

    func stopScan() {
        central.stopScan()
        onMain { if self.bleState == .scanning { self.bleState = .idle } }
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        onMain { self.bleState = .connecting }
        bleQueue.async { [weak self] in
            guard let self else { return }
            // Drop a pending auto-reconnect to a different radio; its
            // didDisconnect is ignored since it's no longer current.
            if let old = self.peripheral, old.identifier != device.peripheral.identifier {
                self.peripheral = nil
                self.central.cancelPeripheralConnection(old)
            }
            self.userInitiatedDisconnect = false
            self.peripheral = device.peripheral
            device.peripheral.delegate = self
            self.central.connect(device.peripheral)
            self.log("Connecting to \(device.name)...")
        }
    }

    func disconnect() {
        if isDemo { stopDemo(); return }
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.userInitiatedDisconnect = true
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
    }

    // MARK: – Demo mode

    // Simulated radio for App Review / trying the app without hardware.
    // Runs through the same HELLO / desired-state / AX.25 paths as a real
    // radio, minus BLE, audio and mic capture. Call from main.
    func connectDemo() {
        guard !isDemo, peripheral == nil else { return }
        let center = demoLocationProvider?() ?? DemoRadio.defaultCenter
        stopScan()
        isDemo = true
        onDemoSessionChanged?(true)
        bleState = .connecting
        bleQueue.async { [weak self] in
            guard let self else { return }
            let demo = DemoRadio(queue: self.bleQueue, center: center)
            demo.onDeviceState = { [weak self] ds in self?.applyDeviceState(ds) }
            demo.onAx25Frame = { [weak self] data in self?.deliverAx25Frame(data) }
            self.demo = demo
            self.log("Demo mode — simulated radio, nothing is transmitted")
            // Mimic connect + HELLO latency so the UI walks through its states.
            self.bleQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.demo === demo else { return }
                self.applyHello(demo.hello)
                demo.start()
            }
        }
    }

    private func stopDemo() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            self.demo?.stop()
            self.demo = nil
            self.radio.detachTransport()
            self.log("Demo mode ended")
            // Queued behind any state updates the demo already posted to main.
            self.onMain {
                self.isDemo = false
                self.onDemoSessionChanged?(false)
                self.bleState = .idle
                self.hello = nil
                self.deviceState = nil
            }
        }
    }

    func recoverAudioIfNeeded() {
        Task { await audio.recoverIfNeeded() }
    }

    // Transport hook for RadioModuleController — the controller decides what
    // to send and when; this only encodes, gates, and writes. Also where the
    // audio handoff happens: mic capture follows the PTT_REQUESTED flag of
    // frames actually emitted.
    private func sendDesiredState(_ state: HostDesiredState) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            if let demo = self.demo {
                demo.apply(state)
            } else {
                let frame = buildKv4pVendorFrame(command: 0x0D, payload: state.encoded())
                self.gate.submit(frame)
            }
            let ptt = (state.flags & HOST_STATE_PTT_REQUESTED) != 0
            if self.demo == nil && ptt != self.transmitting {
                if ptt {
                    self.startTransmitting()
                } else {
                    self.stopTransmitting()
                }
            }
            self.log(String(format: "→ DesiredState seq=%d tx=%.4f rx=%.4f sq=%d flags=0x%04X bw=%d tone=%d",
                            state.sequence, state.freqTx, state.freqRx, state.squelch,
                            state.flags, state.bw, state.ctcssTx))
        }
    }

    // Sends raw AX.25 bytes (no FCS) for the firmware's AFSK modem to
    // transmit. Firmware keys/unkeys PTT itself, and drops the frame unless
    // TX_ALLOWED (band-plan derived, see RadioModuleController) is set.
    func sendAx25Frame(_ ax25: Data) {
        let frame = buildKissDataFrame(ax25)
        bleQueue.async { [weak self] in
            guard let self else { return }
            if let demo = self.demo { demo.receiveAx25(ax25) } else { self.gate.submit(frame) }
        }
        log("→ AX.25 \(ax25.count)B")
    }

    @ObservationIgnored private var txAudioFrameCount = 0

    private func sendTxAudio(_ adpcmFrame: Data) {
        let frame = buildKv4pVendorFrame(command: 0x0C, payload: adpcmFrame)
        gate.submit(frame)
        txAudioFrameCount += 1
        if txAudioFrameCount % 25 == 1 {
            print("[BLE] TX audio #\(txAudioFrameCount) payload=\(adpcmFrame.count)B wire=\(frame.count)B periph=\(peripheral != nil) rxChar=\(rxChar != nil)")
        }
    }

    private func startTransmitting() {
        guard !transmitting else { return }
        transmitting = true
        txAudioFrameCount = 0
        Task { [weak self] in
            guard let self else { return }
            await self.audio.stopMicCapture()
            await self.audio.startMicCapture { [weak self] adpcmFrame in
                guard let self else { return }
                self.bleQueue.async {
                    self.sendTxAudio(adpcmFrame)
                }
            }
            self.log("TX: mic capture started")
        }
    }

    private func stopTransmitting() {
        guard transmitting else { print("[BLE] stopTransmitting: already stopped"); return }
        transmitting = false
        print("[BLE] stopTransmitting: firing stopMicCapture task")
        Task { [weak self] in
            guard let self else { print("[BLE] stopTransmitting: self deallocated"); return }
            print("[BLE] stopTransmitting: awaiting stopMicCapture")
            await self.audio.stopMicCapture()
            print("[BLE] stopTransmitting: stopMicCapture done")
            self.log("TX: mic capture stopped")
        }
    }

    // MARK: – CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onMain { self.bleUnavailable = false }
            log("BLE ready")
        case .poweredOff:
            let demoActive = demo != nil
            onMain {
                self.bleUnavailable = true
                if !demoActive { self.bleState = .idle }
            }
            log("BLE powered off")
        case .unauthorized:
            onMain { self.bleUnavailable = true }
            log("BLE unauthorized — check permissions")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "KV4P-HT"
        let rssi = RSSI.intValue
        onMain {
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discoveredDevices[idx].rssi = rssi
            } else {
                self.discoveredDevices.append(DiscoveredDevice(
                    id: peripheral.identifier, peripheral: peripheral, name: name, rssi: rssi))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onMain { self.bleState = .connected }
        helloReceived = false
        resubscribeAttempted = false
        log("Connected — discovering services")
        // Firmware drops unsubscribed clients at 10s; don't wait longer.
        armSetupWatchdog(after: 10) { [weak self] in
            self?.dropLinkForRetry("notifications never became active")
        }
        peripheral.discoverServices([BLE_KISS_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onMain { self.bleState = .idle }
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A radio we already switched away from (see connect()).
        guard peripheral.identifier == self.peripheral?.identifier else {
            log("Dropped stale link to \(peripheral.name ?? "radio")")
            return
        }
        let shouldReconnect = !userInitiatedDisconnect
        userInitiatedDisconnect = false
        setupToken &+= 1
        helloReceived = false
        onMain {
            self.bleState = shouldReconnect ? .connecting : .idle
            self.hello = nil
            self.deviceState = nil
            self.audioPlaying = false
        }
        self.peripheral = nil
        txChar = nil
        rxChar = nil
        audioFrameCount = 0
        transmitting = false
        parser.reset()
        radio.detachTransport()
        gate.reset()
        Task { [weak self] in
            guard let self else { return }
            // stop() must finish before a reconnect's audio.start() —
            // serialize through the actor, then queue the reconnect.
            await self.audio.stop()
            guard shouldReconnect else { return }
            self.bleQueue.async {
                // User disconnected, picked a radio, or started demo while
                // audio was stopping — don't fight them.
                if self.userInitiatedDisconnect {
                    self.userInitiatedDisconnect = false
                    self.onMain { self.bleState = .idle }
                    return
                }
                guard self.peripheral == nil, self.demo == nil else { return }
                // Pending connects never time out; with bluetooth-central
                // background mode iOS wakes us when the radio reappears.
                self.peripheral = peripheral
                peripheral.delegate = self
                self.central.connect(peripheral)
                self.log("Reconnecting when radio reappears...")
            }
        }
        log(error == nil ? "Disconnected"
                         : "Disconnected unexpectedly: \(error!.localizedDescription)")
    }

    // MARK: – CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            dropLinkForRetry("service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BLE_KISS_SERVICE_UUID }) else {
            dropLinkForRetry("KISS service missing")
            return
        }
        peripheral.discoverCharacteristics([BLE_KISS_TX_CHAR_UUID, BLE_KISS_RX_CHAR_UUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == BLE_KISS_SERVICE_UUID }) else { return }
        log("KISS service invalidated — rediscovering")
        txChar = nil
        rxChar = nil
        peripheral.discoverServices([BLE_KISS_SERVICE_UUID])
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            dropLinkForRetry("characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics,
              chars.contains(where: { $0.uuid == BLE_KISS_TX_CHAR_UUID }),
              chars.contains(where: { $0.uuid == BLE_KISS_RX_CHAR_UUID })
        else {
            dropLinkForRetry("KISS characteristics missing")
            return
        }
        for char in chars {
            switch char.uuid {
            case BLE_KISS_TX_CHAR_UUID:
                txChar = char
                peripheral.setNotifyValue(true, for: char)
                log("TX char found — subscribing")
            case BLE_KISS_RX_CHAR_UUID:
                rxChar = char
                log("RX char found")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BLE_KISS_TX_CHAR_UUID, !helloReceived else { return }
        if let error {
            dropLinkForRetry("notify subscribe failed: \(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            log("TX notifications active — waiting for HELLO (~1s)")
            armSetupWatchdog(after: 3) { [weak self] in
                guard let self else { return }
                guard !self.resubscribeAttempted else {
                    self.dropLinkForRetry("no HELLO after resubscribe")
                    return
                }
                // Likely a reused link whose firmware session never ended.
                // CCCD off→on makes the firmware reset the session and resend
                // HELLO.
                self.resubscribeAttempted = true
                self.log("No HELLO — toggling notifications to restart firmware session")
                peripheral.setNotifyValue(false, for: characteristic)
                self.armSetupWatchdog(after: 5) { [weak self] in
                    self?.dropLinkForRetry("notify toggle stalled")
                }
            }
        } else if resubscribeAttempted {
            // Give the firmware loop time to observe the unsubscribed state.
            bleQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.peripheral === peripheral, !self.helloReceived,
                      peripheral.state == .connected else { return }
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        let frames = parser.feed(data)
        for (cmd, payload) in frames {
            switch cmd {
            case 0x06: handleVendorFrame(payload)
            case 0x00: deliverAx25Frame(payload)
            default:   break
            }
        }
    }

    // MARK: – Private

    private func handleVendorFrame(_ payload: Data) {
        guard payload.count >= 6,
              payload.prefix(4) == Data(KV4P_VENDOR_PREFIX),
              payload[4] == KV4P_PROTOCOL_VERSION
        else { return }

        let command = payload[5]
        let body    = payload.dropFirst(6)

        // A reused link can carry a stale firmware session's audio, window
        // and state frames before HELLO; they'd seed the controller and gate
        // with the wrong baseline.
        if !helloReceived && (command == 0x0C || command == 0x09 || command == 0x0B) { return }

        switch command {
        case 0x06:
            if let h = parseHello(Data(body)) {
                gate.setWindow(Int(h.windowSize))
                applyHello(h)
            }
        case 0x0C:
            audioFrameCount += 1
            let frameData = Data(body)
            audio.feedAdpcmFrame(frameData)
            // ~64 ADPCM frames/sec; log RX audio level + RSSI once per second to
            // diagnose SA818 front-end overload (peak pinned ~1.0 + clips = the
            // RX audio is clipping, which garbles AFSK/APRS decode).
            if audioFrameCount % 64 == 0 {
                let s = audio.takeRxStats()
                let rssi = deviceState?.rssi ?? 0
                log(String(format: "RX audio: peak=%.2f clips=%d rssi=%d sq=%@",
                           s.peak, s.clips, Int(rssi),
                           radio.isSquelched ? "closed" : "OPEN"))
            }
        case 0x09:
            if let size = parseWindowUpdate(Data(body)) {
                gate.enlargeWindow(by: Int(size))
            }
        case 0x0B:
            if let ds = parseDeviceState(Data(body)) {
                applyDeviceState(ds)
            }
        case 0x01, 0x02, 0x03:
            // Drop the firmware's periodic loop-frequency spam; keep other debug.
            if let s = String(bytes: body, encoding: .utf8),
               !s.contains("measureLoopFrequency") { log("← DBG: \(s)") }
        default:
            break
        }
    }

    // HELLO = FirmwareVersion + initial DeviceState. Seed both into the
    // controller and surface the applied state to the UI before any
    // app-driven changes go out. Shared by the BLE and demo transports.
    private func applyHello(_ h: HelloFrame) {
        helloReceived = true
        setupToken &+= 1
        radio.attachTransport { [weak self] state in self?.sendDesiredState(state) }
        radio.seedFirmwareInfo(h)
        radio.seedFromDeviceState(h.deviceState)
        onMain {
            self.hello = h
            self.deviceState = h.deviceState
            self.bleState = .ready
        }
        log(String(format: "← HELLO fw=%d %@ %.0f–%.0f MHz win=%d",
            h.firmwareVersion,
            h.rfModuleType == 0 ? "VHF" : "UHF",
            h.minFreq, h.maxFreq, h.windowSize))
        if demo == nil {
            Task {
                await audio.start()
                let playing = await audio.isPlaying
                self.onMain { self.audioPlaying = playing }
                self.log(playing ? "Audio engine started" : "Audio engine failed to start")
            }
        }
        // App-required desired-state changes only; the controller diffs
        // against the seeded baseline and emits a single update without
        // overwriting unrelated firmware config. TX_ALLOWED was re-derived
        // from the band plan when seeded above and rides in the same frame.
        radio.beginUpdate()
        radio.markTransportReady()
        radio.disableHardwareDeemphasis()
        radio.openAudio()  // ESP32 won't stream audio until RX_AUDIO_OPEN is set
        radio.endUpdate()
        onTransportReady?()
    }

    private func applyDeviceState(_ ds: DeviceStateFrame) {
        radio.updateDeviceState(ds)
        onMain {
            self.deviceState = ds
            self.onDeviceState?(ds)
        }
    }

    private func deliverAx25Frame(_ payload: Data) {
        if let f = AX25Frame(decoding: payload),
           let info = String(data: f.payload, encoding: .ascii)
                    ?? String(data: f.payload, encoding: .isoLatin1) {
            log("← AX.25 \(f.source.display)>\(f.destination.display): \(info.prefix(64))")
        } else {
            log("← AX.25 \(payload.count)B (undecodable)")
        }
        onAx25Frame?(payload)
    }

    // Runs onStall on bleQueue unless HELLO arrives, the link drops, or a
    // newer watchdog is armed first.
    private func armSetupWatchdog(after seconds: Double, onStall: @escaping () -> Void) {
        setupToken &+= 1
        let token = setupToken
        bleQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.setupToken == token, !self.helloReceived else { return }
            onStall()
        }
    }

    // Not user-initiated, so didDisconnect queues an auto-reconnect.
    private func dropLinkForRetry(_ reason: String) {
        log("Setup stalled (\(reason)) — dropping link to retry")
        setupToken &+= 1
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func writeRaw(_ data: Data) {
        guard let p = peripheral, let char = rxChar else { return }
        let mtu    = p.maximumWriteValueLength(for: .withoutResponse)
        var offset = 0
        while offset < data.count {
            let end   = min(offset + mtu, data.count)
            p.writeValue(Data(data[offset..<end]), for: char, type: .withoutResponse)
            offset = end
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(msg)"
        print("[BLE] \(entry)")
        pendingLogEntries.append(entry)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let batch = self.pendingLogEntries
            self.pendingLogEntries = []
            self.logFlushScheduled = false
            self.logEntries.insert(contentsOf: batch.reversed(), at: 0)
            if self.logEntries.count > 100 {
                self.logEntries.removeSubrange(100...)
            }
        }
    }
}
