import Foundation
import CoreLocation

/// Simulated kv4p HT for App Review and hands-on demos without hardware.
///
/// Stands in for the firmware behind BLEManager: provides a HELLO, echoes
/// each HostDesiredState back as the applied DeviceState, opens squelch
/// periodically for fake traffic, and feeds canned APRS packets from
/// fictional DEMO* stations around `center`. Outgoing APRS messages get an
/// ack and a short reply. Nothing is transmitted and no audio is produced.
///
/// Confined to the queue passed to init (BLEManager's bleQueue); callbacks
/// fire on that queue.
nonisolated final class DemoRadio: @unchecked Sendable {
    static let deviceName = "kv4p HT Demo"
    // Apple Park — App Review's likely location when the phone has no fix.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
    // Base callsigns of the fictional stations emitNextPacket() plays back.
    // Not valid amateur calls, so they can't collide with real traffic.
    static let stationCallsigns: Set<String> = ["DEMO", "DEMO1", "DEMO2", "DEMO3", "DEMO4", "DEMOWX"]
    // Canned reply to outgoing messages; sent as whatever callsign was addressed.
    static let replyText = "Copy that! 73 from the demo station"
    static let replyMsgNumPrefix = "D"

    var onDeviceState: ((DeviceStateFrame) -> Void)?
    var onAx25Frame: ((Data) -> Void)?

    private let queue: DispatchQueue
    private let center: CLLocationCoordinate2D
    private var timer: DispatchSourceTimer?
    private var running = false

    // Firmware-applied config, as if loaded from NVS at boot.
    private var desired = HostDesiredState(
        sequence: 0, memoryId: -1,
        flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER
            | HOST_STATE_RSSI_ENABLED | HOST_STATE_FILTER_LOW,
        bw: DRA818_25K, freqTx: 146.52, freqRx: 146.52,
        ctcssTx: 0, squelch: 3, ctcssRx: 0)

    // Simulated RF activity, advanced once per tick (1 s).
    private var carrierPresent = false
    private var ticksUntilToggle = 4
    private var packetTxTicks = 0   // firmware keys TX briefly for AX.25 frames
    private var ticksUntilPacket = 2
    private var packetIndex = 0
    private var mobileStep = 0
    // Seconds before the simulated peer acks / replies to an outgoing message.
    var replyDelays: (ack: Double, reply: Double) = (2, 5)

    init(queue: DispatchQueue, center: CLLocationCoordinate2D) {
        self.queue = queue
        self.center = center
    }

    var hello: HelloFrame {
        HelloFrame(
            firmwareVersion: 17, radioModuleFound: true,
            windowSize: UInt32(FlowControlGate.defaultWindow),
            rfModuleType: 0, minFreq: 134, maxFreq: 174,
            features: 0x01,  // high/low power switch
            deviceState: currentState())
    }

    func start() {
        guard !running else { return }
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
    }

    // MARK: - Host → radio

    func apply(_ state: HostDesiredState) {
        desired = state
        publish()
    }

    func receiveAx25(_ ax25: Data) {
        packetTxTicks = 2
        publish()
        guard let frame = AX25Frame(decoding: ax25),
              case let .message(to, _, msgNum?, false, false) = parseAPRSPayload(frame.payload),
              !to.hasPrefix("BLN"),
              let peer = AX25Callsign(parsing: to)
        else { return }
        let me = frame.source.display
        after(replyDelays.ack) { [weak self] in
            self?.emit(from: peer, payload: messagePayload(to: me, text: "ack\(msgNum)", msgNum: nil))
        }
        // Random msgNum: the app dedupes directed messages on (source, msgNum)
        // across sessions.
        let replyNum = Self.replyMsgNumPrefix + String(Int.random(in: 1000...9999))
        after(replyDelays.reply) { [weak self] in
            self?.emit(from: peer, payload: messagePayload(
                to: me, text: Self.replyText, msgNum: replyNum))
        }
    }

    // MARK: - Simulation

    private func tick() {
        guard running else { return }
        if packetTxTicks > 0 { packetTxTicks -= 1 }

        ticksUntilToggle -= 1
        if ticksUntilToggle <= 0 {
            carrierPresent.toggle()
            ticksUntilToggle = carrierPresent ? Int.random(in: 3...7) : Int.random(in: 8...16)
        }

        ticksUntilPacket -= 1
        if ticksUntilPacket <= 0 {
            ticksUntilPacket = 10
            emitNextPacket()
        }
        publish()
    }

    private func publish() {
        guard running else { return }
        onDeviceState?(currentState())
    }

    private func currentState() -> DeviceStateFrame {
        let txAllowed = (desired.flags & HOST_STATE_TX_ALLOWED) != 0
        let pttRequested = (desired.flags & HOST_STATE_PTT_REQUESTED) != 0
        let tx = txAllowed && (pttRequested || packetTxTicks > 0)
        let open = !tx && (carrierPresent || desired.squelch == 0)
        var flags = desired.flags
        if tx { flags |= DEVICE_STATE_TX_ACTIVE }
        if !tx && !open { flags |= DEVICE_STATE_SQUELCHED }
        let rssi: UInt8 = tx ? 0
            : carrierPresent ? UInt8.random(in: 70...130)
            : UInt8.random(in: 22...34)
        return DeviceStateFrame(
            appliedSequence: desired.sequence, memoryId: desired.memoryId,
            flags: flags, bw: desired.bw,
            freqTx: desired.freqTx, freqRx: desired.freqRx,
            ctcssTx: desired.ctcssTx, squelch: desired.squelch, ctcssRx: desired.ctcssRx,
            radioModuleStatus: RADIO_STATUS_FOUND, mode: tx ? 0 : 1,
            lastError: 0, rssi: rssi)
    }

    private func emitNextPacket() {
        defer { packetIndex += 1 }
        if packetIndex == 0 {
            emit(from: "DEMO", payload: messagePayload(
                to: "BLN1", text: "Demo mode: all stations and signals are simulated", msgNum: nil))
            return
        }
        switch (packetIndex - 1) % 5 {
        case 0:
            mobileStep += 1
            let d = Double(mobileStep % 20)
            emit(from: "DEMO1-9", payload: "!" + Self.position(
                center.latitude + 0.012 + d * 0.0015, center.longitude - 0.025 + d * 0.0025,
                table: "/", code: ">") + "Demo mobile, monitoring 146.520")
        case 1:
            let temp = Int.random(in: 64...71)
            emit(from: "DEMOWX", payload: "!" + Self.position(
                center.latitude - 0.018, center.longitude + 0.021, table: "/", code: "_")
                + String(format: "%03d/%03dg%03dt%03dr000p000P000h%02db10132",
                         Int.random(in: 0...35) * 10, Int.random(in: 2...9),
                         Int.random(in: 10...16), temp, Int.random(in: 40...60)))
        case 2:
            emit(from: "DEMO2-7", payload: "!" + Self.position(
                center.latitude + 0.031, center.longitude + 0.012,
                table: "/", code: "[") + "Hiking the ridge trail, 5W HT")
        case 3:
            emit(from: "DEMO3", payload: "!" + Self.position(
                center.latitude - 0.009, center.longitude - 0.034,
                table: "/", code: "-") + "Home station, QRV on 2 m")
        default:
            emit(from: "DEMO4", payload: "!" + Self.position(
                center.latitude + 0.044, center.longitude - 0.006,
                table: "/", code: "#") + "Demo digipeater, WIDE1-1")
        }
    }

    private func emit(from source: String, payload: String) {
        guard let call = AX25Callsign(parsing: source) else { return }
        emit(from: call, payload: payload)
    }

    private func emit(from source: AX25Callsign, payload: String) {
        guard running else { return }
        let frame = AX25Frame(
            destination: AX25Callsign(base: "APRS", ssid: 0), source: source,
            digipeaters: [AX25Callsign(base: "WIDE1", ssid: 1, hasBeenRepeated: true)],
            payload: Data(payload.utf8))
        onAx25Frame?(frame.encodedWithoutFCS())
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.running == true else { return }
            work()
        }
    }

    // Uncompressed "ddmm.mmN/dddmm.mmW>" (19 chars).
    private static func position(_ lat: Double, _ lon: Double,
                                 table: Character, code: Character) -> String {
        func degMin(_ v: Double, width: Int) -> String {
            let a = abs(v)
            let deg = Int(a)
            let min = ((a - Double(deg)) * 60 * 100).rounded(.down) / 100
            return String(format: "%0\(width)d%05.2f", deg, min)
        }
        return degMin(lat, width: 2) + (lat >= 0 ? "N" : "S") + String(table)
            + degMin(lon, width: 3) + (lon >= 0 ? "E" : "W") + String(code)
    }
}
