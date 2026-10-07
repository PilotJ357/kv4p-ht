import Foundation
import CoreLocation

// MARK: - APRS entry model

enum APRSPacketKind: String, Codable {
    case message, bulletin, weather, position, object, raw
    var label: String {
        switch self {
        case .message:  return "Message"
        case .bulletin: return "Bulletin"
        case .weather:  return "Weather"
        case .position: return "Position"
        case .object:   return "Object"
        case .raw:      return "Other"
        }
    }
}

struct APRSEntry: Identifiable, Codable {
    var id = UUID()
    var fromCallsign: String
    var toCallsign: String
    var kind: APRSPacketKind
    var text: String
    var timestamp: Date
    var lat: Double?
    var lon: Double?
    var symbolTable: String?
    var symbolCode: String?
    var objName: String?
    var msgNum: String?
    var wasAcknowledged: Bool = false
    // Digipeater that repeated our outgoing packet (nil = not heard yet).
    var heardViaDigi: String? = nil
    // Retry state for outgoing directed messages (APRS decay algorithm).
    var retryCount: Int = 0
    var nextRetryAt: Date? = nil
    var isOutgoing: Bool = false
    var weather: APRSWeather?

    var callsign: String { isOutgoing && kind == .message ? toCallsign : fromCallsign }

    // A directed message still retrying toward an ack.
    var isAwaitingAck: Bool {
        isOutgoing && kind == .message && !wasAcknowledged && nextRetryAt != nil
    }
    // A directed message that exhausted its retries without an ack.
    var isUndelivered: Bool {
        isOutgoing && kind == .message && !wasAcknowledged
            && nextRetryAt == nil && retryCount >= APRSController.maxRetries
    }

    var time: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(timestamp) ? .none : .short
        return f.string(from: timestamp)
    }

    func distanceMi(from location: CLLocation?) -> Double? {
        guard let lat, let lon, let location else { return nil }
        let meters = location.distance(from: CLLocation(latitude: lat, longitude: lon))
        return meters / 1609.344
    }
}

// MARK: - Controller

@Observable
class APRSController {
    @ObservationIgnored weak var store: RadioStore?
    @ObservationIgnored weak var notifier: APRSNotifying?

    private static let legacyEntriesKey = "aprsEntries"
    private static let msgNumKey = "aprsMessageNumber"
    private static let maxEntries = 500
    // Exact-duplicate suppression for digipeated copies of any packet.
    private static let frameDedupeWindow: TimeInterval = 30
    // Directed-message dedupe/re-ack window. Long and restart-proof: a sender
    // retrying an unacked message minutes later (or after we relaunch) must be
    // re-acked without a duplicate visible entry.
    private static let messageDedupeWindow: TimeInterval = 30 * 60
    private static let frameRetention: TimeInterval = 24 * 60 * 60
    // Digipeats arrive within seconds of TX; window is generous for slow nets.
    private static let heardViaDigiTTL: TimeInterval = 120
    private static let maxMessageNum = 99999

    // APRS decay-algorithm retry for unacked directed messages: first retry 8s
    // after send, doubling each time, capped at the 20-min net cycle time, then
    // give up. See https://www.aprs.org/txt/messages101.txt.
    private static let retryBaseInterval: TimeInterval = 8
    private static let retryIntervalCap: TimeInterval = 20 * 60
    static let maxRetries = 7
    private static let retryTickInterval: TimeInterval = 5

    // Interval before the nth retry (0-based): 8, 16, 32, … capped at the cap.
    static func retryInterval(forAttempt n: Int) -> TimeInterval {
        min(retryBaseInterval * pow(2, Double(n)), retryIntervalCap)
    }

    // State after one retransmission: bump the count, schedule the next retry —
    // or stop (nextRetryAt = nil → undelivered) once the limit is reached.
    static func nextRetryState(retryCount: Int, now: Date)
        -> (retryCount: Int, nextRetryAt: Date?) {
        let attempt = retryCount + 1
        let next = attempt >= maxRetries
            ? nil : now.addingTimeInterval(retryInterval(forAttempt: attempt))
        return (attempt, next)
    }

    var entries: [APRSEntry] = []

    // The durable store; `persistence` points at a throwaway in-memory store
    // instead while a demo session runs.
    @ObservationIgnored private let realPersistence: APRSPersistence
    @ObservationIgnored private var persistence: APRSPersistence
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var beaconTimer: Timer?
    @ObservationIgnored private var beaconDeferTimer: Timer?
    @ObservationIgnored private var beaconGate = BeaconDeferGate()
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var messageNumber: Int
    // Real counter parked while demo messages draw from a scratch copy.
    @ObservationIgnored private var realMessageNumber: Int?
    // Bumped on each demo start/stop so delayed work (acks) from one session
    // never fires into the next — e.g. an ack to a DEMO station over real RF.
    @ObservationIgnored private var sessionGeneration = 0

    init(persistence: APRSPersistence = APRSPersistence(),
         defaults: UserDefaults = .standard) {
        self.realPersistence = persistence
        self.persistence = persistence
        self.defaults = defaults
        messageNumber = defaults.object(forKey: Self.msgNumKey) as? Int
            ?? Int.random(in: 0...Self.maxMessageNum)
        // One-shot migration of the pre-Core Data UserDefaults history blob.
        if let data = defaults.data(forKey: Self.legacyEntriesKey) {
            persistence.migrateLegacyEntries(data)
            defaults.removeObject(forKey: Self.legacyEntriesKey)
        }
        // Builds before demo isolation persisted demo traffic; drop it.
        persistence.purgeDemoTraffic()
        entries = persistence.loadEntries(max: Self.maxEntries)
        startRetryTimer()
    }

    // MARK: - Demo session

    var isDemoSession: Bool { realMessageNumber != nil }

    // Demo traffic is fictional: route it to an in-memory store that's
    // discarded on exit, so it never reaches the real history (or its dedupe
    // frames) even if the app is killed mid-demo. Real history is hidden for
    // the session and restored by endDemoSession().
    func beginDemoSession() {
        guard !isDemoSession else { return }
        sessionGeneration &+= 1
        realMessageNumber = messageNumber
        persistence = APRSPersistence(inMemory: true)
        entries = []
    }

    func endDemoSession() {
        guard let saved = realMessageNumber else { return }
        sessionGeneration &+= 1
        realMessageNumber = nil
        messageNumber = saved
        persistence = realPersistence
        entries = persistence.loadEntries(max: Self.maxEntries)
    }

    private func append(_ entry: APRSEntry, frameHash: String? = nil) {
        entries.append(entry)
        persistence.insertEntry(entry, frameHash: frameHash)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            persistence.trimEntries(max: Self.maxEntries)
        }
        notifyIfNeeded(entry)
        if !entry.isOutgoing { store?.liveActivity.received(entry) }
    }

    // Hand a received entry to the notifier, which applies the full gate
    // (kind/addressed/distance/mute/cooldown). Outgoing entries never notify.
    private func notifyIfNeeded(_ entry: APRSEntry) {
        guard !entry.isOutgoing, let store, store.aprsNotify.enabled,
              let notifier else { return }
        let addressed = isAddressedToMe(entry.toCallsign)
        // A stale fix would filter against where we used to be; treat it as
        // unknown (no distance filtering) instead.
        let here = store.locationManager.location(maxAge: Self.notifyFixMaxAge)
        let dist = entry.distanceMi(from: here)
        notifier.consider(entry, settings: store.aprsNotify,
                           isAddressedToMe: addressed, distanceMi: dist, now: Date())
    }

    func clearAll() {
        entries.removeAll()
        persistence.deleteAllEntries()
    }

    // MARK: - My station

    private var myCallsign: AX25Callsign? {
        guard let store, !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let base = store.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        let ssidDigits = store.aprsSSID.filter(\.isNumber)
        let ssid = UInt8(ssidDigits).map { min($0, 15) } ?? 0
        return AX25Callsign(base: base, ssid: ssid)
    }

    private func isAddressedToMe(_ target: String) -> Bool {
        guard let me = myCallsign else { return false }
        return target == me.display || target == me.base
    }

    // MARK: - RX

    // RX pipeline: decode identity → persist the frame → classify → side
    // effects. The persistent frame store, not an in-memory cache, decides
    // what counts as a duplicate, so dedupe and re-ack survive app restarts.
    func handleAx25Frame(_ data: Data) {
        guard let frame = AX25Frame(decoding: data) else { return }

        let now = Date()
        var from = frame.source.display
        var to = frame.destination.display
        var info = parseMicEPayload(frame.payload, destCall: frame.destination.base)
            ?? parseAPRSPayload(frame.payload)

        // Third-party relayed traffic (} DTI): the real originator is the inner
        // packet's source, not the RF-carrying station. Unwrap so the message
        // shows as from the originator and auto-ack targets them, not the
        // gateway. (Ported from Android Parser.java case '}'.)
        if let tp = Self.unwrapThirdParty(frame.payload) {
            from = tp.source
            to = tp.destination
            info = parseMicEPayload(tp.info, destCall: tp.destination)
                ?? parseAPRSPayload(tp.info)
        }

        let (frameKind, frameMsgNum) = Self.frameIdentity(of: info)

        // Identify a directed message (carries a msgNum, not an ack/rej/bulletin)
        // so it can be deduped by identity and acked.
        var directedTarget: String?
        var directedMsgNum: String?
        if case let .message(target, _, msgNum, isAck, isRej) = info,
           !isAck, !isRej, !target.hasPrefix("BLN"), let num = msgNum {
            directedTarget = target
            directedMsgNum = num
        }

        // Directed messages get the long window and dedupe on identity
        // (source, msgNum) — path-stable across sender retries, digipeated
        // copies, and third-party relays whose outer header drifts. Everything
        // else dedupes on payload bytes and only needs digipeat suppression.
        let window = directedMsgNum != nil ? Self.messageDedupeWindow : Self.frameDedupeWindow
        let since = now.addingTimeInterval(-window)
        let isDuplicate: Bool
        if let num = directedMsgNum {
            isDuplicate = persistence.recentIncomingMessageExists(
                source: from, msgNum: num, since: since)
        } else {
            isDuplicate = persistence.recentIncomingFrameExists(
                source: from, payload: frame.payload, since: since)
        }

        // Persist before any side effects.
        let frameHash = APRSPersistence.frameHash(of: data)
        persistence.insertFrame(
            direction: "in", raw: data, frameHash: frameHash,
            source: from, destination: to, payload: frame.payload,
            kind: frameKind, msgNum: frameMsgNum, timestamp: now)
        persistence.pruneFrames(olderThan: now.addingTimeInterval(-Self.frameRetention))

        // Our own packet repeated back by a digipeater — don't show it as a
        // received entry, mark the matching outgoing entry as heard instead.
        if let me = myCallsign, frame.source.display == me.display {
            markHeardViaDigi(info, frame: frame)
            return
        }

        // ACK every directed message addressed to us — first copy or retry. A
        // sender retry means our previous ack was lost; the spec requires
        // re-acking each copy, so the ack is never gated by the dedupe decision.
        if let target = directedTarget, let num = directedMsgNum, isAddressedToMe(target) {
            scheduleAck(to: from, msgNum: num)
        }

        // Duplicates (digipeated copies, sender retries) are acked above but
        // aren't shown as a new entry again.
        if isDuplicate { return }

        switch info {
        case let .position(lat, lon, table, code, comment, weather):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: weather != nil ? .weather : .position,
                text: weather?.summary ?? comment,
                timestamp: now, lat: lat, lon: lon,
                symbolTable: String(table), symbolCode: String(code),
                weather: weather), frameHash: frameHash)

        case let .message(target, body, msgNum, isAck, isRej):
            if isAck || isRej {
                if isAddressedToMe(target), let num = msgNum {
                    markAcknowledged(msgNum: num, by: from, rejected: isRej)
                }
                return
            }
            // Directed messages addressed to us are acked earlier (every copy);
            // here we only record the visible entry.
            let kind: APRSPacketKind = target.hasPrefix("BLN") ? .bulletin : .message
            append(APRSEntry(
                fromCallsign: from, toCallsign: target,
                kind: kind, text: body, timestamp: now, msgNum: msgNum),
                frameHash: frameHash)

        case let .object(name, lat, lon, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .object, text: comment.isEmpty ? name : "\(name): \(comment)",
                timestamp: now, lat: lat, lon: lon, objName: name), frameHash: frameHash)

        case let .weather(wx, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .weather, text: wx.summary.isEmpty ? comment : wx.summary,
                timestamp: now, weather: wx), frameHash: frameHash)

        case let .raw(text):
            guard !text.isEmpty else { return }
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .raw, text: text, timestamp: now), frameHash: frameHash)
        }
    }

    // Minimal parsed identity stored alongside the raw frame.
    private static func frameIdentity(of info: APRSInfo) -> (kind: String?, msgNum: String?) {
        switch info {
        case let .message(_, _, msgNum, isAck, isRej):
            return (isAck ? "ack" : isRej ? "rej" : "message", msgNum)
        case .position: return ("position", nil)
        case .object:   return ("object", nil)
        case .weather:  return ("weather", nil)
        case .raw:      return ("raw", nil)
        }
    }

    // Unwraps a third-party relayed payload (DTI '}') into the inner packet's
    // source callsign, destination (tocall), and info field. Inner wire format
    // is TNC2: "SRC>DEST,PATH:infofield". Returns nil if the payload isn't
    // third-party or is malformed.
    static func unwrapThirdParty(_ payload: Data) -> (source: String, destination: String, info: Data)? {
        guard let text = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1),
              text.first == "}" else { return nil }
        let inner = text.dropFirst()                       // strip '}'
        guard let gt = inner.firstIndex(of: ">") else { return nil }
        let source = String(inner[inner.startIndex..<gt])
        guard !source.isEmpty else { return nil }
        let afterSource = inner[inner.index(after: gt)...]  // "DEST,PATH:info..."
        guard let colon = afterSource.firstIndex(of: ":") else { return nil }
        let header = afterSource[afterSource.startIndex..<colon]  // "DEST,PATH"
        let dest = header.split(separator: ",").first.map(String.init) ?? ""
        // Drop the TNC2 header/info separator colon; the info field keeps its
        // own DTI (e.g. ':' for a message, '!' for a position).
        let infoStr = String(afterSource[afterSource.index(after: colon)...])
        guard !infoStr.isEmpty, let infoData = infoStr.data(using: .utf8)
        else { return nil }
        // Trailing '*' on a digipeated callsign isn't part of the name.
        let cleanDest = dest.hasSuffix("*") ? String(dest.dropLast()) : dest
        return (source.uppercased(), cleanDest.uppercased(), infoData)
    }

    // A digipeated copy of our own packet means we were heard on RF. Mark the
    // newest matching outgoing entry; repeats from further digis are no-ops
    // because already-heard entries are skipped.
    private func markHeardViaDigi(_ info: APRSInfo, frame: AX25Frame) {
        let digi = frame.digipeaters.first(where: \.hasBeenRepeated)?.display
            ?? "digipeater"
        let cutoff = Date().addingTimeInterval(-Self.heardViaDigiTTL)
        for i in entries.indices.reversed() {
            let e = entries[i]
            guard e.isOutgoing, e.heardViaDigi == nil, e.timestamp > cutoff
            else { continue }
            switch info {
            case let .message(target, _, msgNum, _, _):
                guard e.kind == .message || e.kind == .bulletin,
                      callsignsMatch(e.toCallsign, target),
                      msgNum.map({ msgNumsMatch(e.msgNum, $0) }) ?? (e.msgNum == nil)
                else { continue }
            case .position:
                guard e.kind == .position else { continue }
            default:
                break
            }
            entries[i].heardViaDigi = digi
            persistence.markEntryHeardViaDigi(id: entries[i].id, digi: digi)
            return
        }
    }

    private func markAcknowledged(msgNum: String, by callsign: String, rejected: Bool) {
        guard !rejected else { return }
        for i in entries.indices.reversed()
        where entries[i].isOutgoing && !entries[i].wasAcknowledged
            && msgNumsMatch(entries[i].msgNum, msgNum)
            && callsignsMatch(entries[i].toCallsign, callsign) {
            entries[i].wasAcknowledged = true
            entries[i].nextRetryAt = nil   // stop retrying an acked message
            persistence.markEntryAcknowledged(id: entries[i].id)
            return
        }
    }

    // Exact display match, or same base callsign (acks may come back with a
    // different SSID than the one we addressed).
    private func callsignsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func base(_ s: String) -> Substring { s.split(separator: "-", maxSplits: 1).first ?? Substring(s) }
        return base(a) == base(b)
    }

    // String equality after trimming, or numeric equality ("012" acks "12").
    private func msgNumsMatch(_ a: String?, _ b: String) -> Bool {
        guard let a = a?.trimmingCharacters(in: .whitespaces) else { return false }
        let b = b.trimmingCharacters(in: .whitespaces)
        if a == b { return true }
        if let ai = Int(a), let bi = Int(b) { return ai == bi }
        return false
    }

    // MARK: - TX

    private func isReadyToTransmit() -> Bool {
        guard let store else { return false }
        return store.ble.bleState == .ready && myCallsign != nil
    }

    // Firmware silently drops AX.25 frames unless TX_ALLOWED is set, which
    // the controller only grants while the current TX frequency is in band.
    private func canTransmit() -> Bool {
        isReadyToTransmit() && store?.radio.isTxAllowed == true
    }

    @discardableResult
    private func transmitPayload(_ payload: String, simplexFrequency: Float? = nil) -> Bool {
        guard let store, let me = myCallsign else { return false }
        let frame = AX25Frame(source: me, payload: Data(payload.utf8))
        let raw = frame.encodedWithoutFCS()
        store.notePacketTx()
        store.ble.sendAx25Frame(raw, simplexFrequency: simplexFrequency)
        let info = parseAPRSPayload(frame.payload)
        let (kind, msgNum) = Self.frameIdentity(of: info)
        persistence.insertFrame(
            direction: "out", raw: raw, frameHash: APRSPersistence.frameHash(of: raw),
            source: me.display, destination: frame.destination.display,
            payload: frame.payload, kind: kind, msgNum: msgNum, timestamp: Date())
        return true
    }

    // Delay before acking (matches Android) so we don't key up while
    // digipeated copies of the message are still on the air.
    private func scheduleAck(to: String, msgNum: String) {
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.sessionGeneration == generation else { return }
            self.sendAck(to: to, msgNum: msgNum)
        }
    }

    private func sendAck(to: String, msgNum: String) {
        guard canTransmit() else { return }
        transmitPayload(messagePayload(to: to, text: "ack" + msgNum, msgNum: nil))
    }

    // Returns true if the message was sent.
    @discardableResult
    func sendMessage(to: String?, text: String) -> Bool {
        guard canTransmit() else { return false }
        let outText = text
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "{", with: " ")
        let target = (to?.trimmingCharacters(in: .whitespaces).uppercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "BLN1CQ"

        if messageNumber > Self.maxMessageNum { messageNumber = 0 }
        let num = String(messageNumber)
        messageNumber += 1
        if !isDemoSession { defaults.set(messageNumber, forKey: Self.msgNumKey) }

        guard transmitPayload(messagePayload(to: target, text: outText, msgNum: num))
        else { return false }
        let kind: APRSPacketKind = target.hasPrefix("BLN") ? .bulletin : .message
        // Directed messages start the decay-algorithm retry clock; bulletins
        // are fire-and-forget (no ack expected).
        let nextRetryAt = kind == .message
            ? Date().addingTimeInterval(Self.retryInterval(forAttempt: 0)) : nil
        append(APRSEntry(
            fromCallsign: myCallsign?.display ?? "", toCallsign: target,
            kind: kind, text: outText, timestamp: Date(), msgNum: num,
            nextRetryAt: nextRetryAt, isOutgoing: true))
        return true
    }

    // MARK: - Message retry (decay algorithm)

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.retryTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.processDueRetries() }
        }
    }

    // Retransmits unacked directed messages whose retry is due. A retry is only
    // consumed when actually sent — if BLE is down the message is left pending
    // and picked up on a later tick (or when reconnect kicks this directly).
    func processDueRetries(now: Date = Date()) {
        guard canTransmit() else { return }
        for i in entries.indices {
            let e = entries[i]
            guard e.isOutgoing, e.kind == .message, !e.wasAcknowledged,
                  let due = e.nextRetryAt, due <= now, let num = e.msgNum
            else { continue }
            transmitPayload(messagePayload(to: e.toCallsign, text: e.text, msgNum: num))
            let s = Self.nextRetryState(retryCount: e.retryCount, now: now)
            entries[i].retryCount = s.retryCount
            entries[i].nextRetryAt = s.nextRetryAt
            persistence.updateEntryRetry(
                id: e.id, retryCount: s.retryCount, nextRetryAt: s.nextRetryAt)
        }
    }

    // Manual resend: transmit an unacked directed message now and restart its
    // decay-algorithm budget from the top (fresh 7-retry cycle). Works for both
    // awaiting-ack and exhausted/undelivered messages.
    @discardableResult
    func resendNow(_ id: UUID) -> Bool {
        guard canTransmit(),
              let i = entries.firstIndex(where: { $0.id == id }),
              entries[i].isOutgoing, entries[i].kind == .message,
              !entries[i].wasAcknowledged, let num = entries[i].msgNum
        else { return false }
        guard transmitPayload(
            messagePayload(to: entries[i].toCallsign, text: entries[i].text, msgNum: num))
        else { return false }
        let next = Date().addingTimeInterval(Self.retryInterval(forAttempt: 0))
        entries[i].retryCount = 0
        entries[i].nextRetryAt = next
        persistence.updateEntryRetry(id: id, retryCount: 0, nextRetryAt: next)
        return true
    }

    // MARK: - Position beacon

    enum BeaconResult {
        case sent, notReady, noConsent, outOfBand, staleLocation
        case noLocation(LocationAccess)
    }

    // Beacons publicly broadcast position, so never send an old cached fix
    // (#49). The notification distance filter tolerates more drift.
    nonisolated static let beaconFixMaxAge: TimeInterval = 5 * 60
    nonisolated static let notifyFixMaxAge: TimeInterval = 30 * 60

    // Scheduled beacons pause while backgrounded: with When-In-Use access
    // iOS won't deliver new fixes there, so they could only repeat a stale one.
    @ObservationIgnored private var isBackgrounded = false

    func enterBackground() {
        isBackgrounded = true
        beaconGate.reset()
        cancelBeaconDeferTimer()
    }

    func enterForeground() {
        isBackgrounded = false
        // Warm the fix so the next scheduled beacon has a current position.
        if let store, store.aprsBeaconEnabled, store.aprsBeaconConsented {
            store.locationManager.requestLocation()
        }
    }

    func sendPositionBeacon() async -> BeaconResult {
        guard let store else { return .notReady }
        guard store.aprsBeaconConsented else { return .noConsent }
        guard isReadyToTransmit() else { return .notReady }
        // A fixed beacon frequency is transmitted simplex on that frequency;
        // "Current" goes out on the current TX frequency.
        let beaconFreq = store.aprsBeaconFrequency == "Current" ? nil : Float(store.aprsBeaconFrequency)
        guard beaconFreq.map({ store.radio.canTransmit(onFrequency: $0) }) ?? store.radio.isTxAllowed
        else { return .outOfBand }
        guard let location = await store.locationManager.freshLocation(maxAge: Self.beaconFixMaxAge)
        else {
            return store.locationManager.location == nil
                ? .noLocation(store.locationManager.access) : .staleLocation
        }
        // Waiting for a fix can take seconds; re-check the link and band.
        guard isReadyToTransmit() else { return .notReady }
        guard beaconFreq.map({ store.radio.canTransmit(onFrequency: $0) }) ?? store.radio.isTxAllowed
        else { return .outOfBand }
        var lat = location.coordinate.latitude
        var lon = location.coordinate.longitude
        if store.aprsPositionApprox {
            lat = (lat * 100).rounded() / 100
            lon = (lon * 100).rounded() / 100
        }
        let symbol = store.aprsSymbol.first ?? "["
        let payload = "=" + compressedPositionString(lat: lat, lon: lon, symbolCode: symbol)

        append(APRSEntry(
            fromCallsign: myCallsign?.display ?? "", toCallsign: KV4P_HT_VENDOR_TOCALL,
            kind: .position, text: "Position beacon",
            timestamp: Date(), lat: lat, lon: lon,
            symbolTable: "/", symbolCode: String(symbol), isOutgoing: true))

        // The frame carries the beacon frequency, so firmware tunes there for
        // carrier sense and TX and restores the channel afterwards; a frame
        // held by CSMA can't leak onto whatever is tuned later (#57).
        if let freq = beaconFreq, store.radio.isTxAllowed {
            transmitPayload(payload, simplexFrequency: freq)
        } else if let freq = beaconFreq {
            // Current channel is out of band, so firmware would refuse the
            // frame (no TX_ALLOWED). Retune so the controller grants it.
            await store.withSimplexFrequency(freq) {
                try? await Task.sleep(for: .milliseconds(500))
                transmitPayload(payload, simplexFrequency: freq)
                try? await Task.sleep(for: .seconds(4))
            }
        } else {
            transmitPayload(payload)
        }
        return .sent
    }

    // "Beacon now": always sends immediately, and stands in for a held
    // scheduled beacon.
    func sendManualBeacon() async -> BeaconResult {
        if let store {
            _ = beaconGate.evaluate(.manual, interruptReception: store.aprsBeaconInterruptRx,
                                    squelched: store.isSquelched)
        }
        cancelBeaconDeferTimer()
        return await sendPositionBeacon()
    }

    // MARK: - Beacon timer

    func updateBeaconTimer() {
        beaconTimer?.invalidate()
        beaconTimer = nil
        beaconGate.reset()
        cancelBeaconDeferTimer()
        guard let store, store.aprsBeaconEnabled, store.aprsBeaconConsented else { return }
        let interval = TimeInterval(max(1, store.aprsBeaconIntervalMin)) * 60
        beaconTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scheduledBeacon(.interval)
            }
        }
    }

    private func scheduledBeacon(_ trigger: BeaconDeferGate.Trigger) async {
        guard let store, store.aprsBeaconEnabled, !store.isScanning, !isBackgrounded else {
            beaconGate.reset()
            return
        }
        switch beaconGate.evaluate(trigger, interruptReception: store.aprsBeaconInterruptRx,
                                   squelched: store.isSquelched) {
        case .send:
            // The fix wait inside can outlast a backgrounding; don't send then.
            guard !isBackgrounded else { return }
            _ = await sendPositionBeacon()
        case .hold:
            scheduleBeaconRetry()
        case .skip:
            break
        }
    }

    private func scheduleBeaconRetry() {
        beaconDeferTimer?.invalidate()
        beaconDeferTimer = Timer.scheduledTimer(
            withTimeInterval: BeaconDeferGate.retryInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.scheduledBeacon(.retry)
            }
        }
    }

    private func cancelBeaconDeferTimer() {
        beaconDeferTimer?.invalidate()
        beaconDeferTimer = nil
    }
}
