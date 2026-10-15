import Foundation

// Fill-in digipeater, ported from java-aprs 0.2.5 AprsController.maybeDigipeat
// (what Android's "Digipeat packets" setting turns on). Only the first unused
// path hop is considered. It's eligible when it is WIDE1-1 (fill-in) or our
// own callsign (explicitly routed through us), and is replaced by our
// callsign with the has-been-repeated bit set:
//   SRC>DST,WIDE1-1,WIDE2-1  →  SRC>DST,MYCALL*,WIDE2-1
//   SRC>DST,MYCALL,WIDE2-1   →  SRC>DST,MYCALL*,WIDE2-1
// A logical packet (source, destination, payload — path ignored) is digipeated
// at most once per dedupe window, so copies from other digis are ignored.
//
// Unlike java-aprs, which hands the frame straight to the radio, a digipeat
// waits for squelch to close so we don't key up over traffic. If another copy
// of the packet is heard while ours waits, some other digi already repeated
// it and ours is dropped; one still waiting after maxHold is dropped as stale.
nonisolated struct APRSDigipeater {
    // java-aprs DIGIPEAT_DEDUP_MS.
    static let dedupeWindow: TimeInterval = 28
    static let maxHold: TimeInterval = 10
    // Firmware queues two AX.25 frames and drops a third.
    static let maxPending = 2

    struct Pending {
        let key: String
        let frame: AX25Frame
        let frequency: Float   // receive frequency; retransmitted there only
        let deadline: Date
    }

    private(set) var pending: [Pending] = []
    private var seen: [String: Date] = [:]

    // The digipeated form of `frame`, or nil if we shouldn't repeat it.
    static func rewrite(_ frame: AX25Frame, myCall: AX25Callsign) -> AX25Frame? {
        guard !frame.payload.isEmpty,
              !sameStation(frame.source, myCall),   // our own packet
              // Already repeated by us: never loop it again.
              !frame.digipeaters.contains(where: { $0.hasBeenRepeated && sameStation($0, myCall) }),
              let i = frame.digipeaters.firstIndex(where: { !$0.hasBeenRepeated })
        else { return nil }
        let hop = frame.digipeaters[i]
        let isWide1 = hop.base == "WIDE1" && hop.ssid == 1
        guard isWide1 || sameStation(hop, myCall) else { return nil }
        var out = frame
        out.digipeaters[i] = AX25Callsign(base: myCall.base, ssid: myCall.ssid,
                                          hasBeenRepeated: true)
        return out
    }

    // java-aprs logicalPacketKey: path-independent packet identity.
    static func dedupeKey(of frame: AX25Frame) -> String {
        "\(frame.source.display)|\(frame.destination.display)|\(frame.payload.base64EncodedString())"
    }

    // Busy = squelch open, per the beacon gate's rule. With squelch off (0)
    // the flag can't tell traffic from noise; firmware CSMA still senses
    // carrier before keying up.
    static func isChannelClear(squelchLevel: UInt8, squelched: Bool) -> Bool {
        squelchLevel == 0
            || !BeaconDeferGate.mustWait(interruptReception: false, squelched: squelched)
    }

    private static func sameStation(_ a: AX25Callsign, _ b: AX25Callsign) -> Bool {
        a.base == b.base && a.ssid == b.ssid
    }

    // Feed every received frame. Returns true if a digipeat was queued.
    @discardableResult
    mutating func receive(_ frame: AX25Frame, myCall: AX25Callsign,
                          frequency: Float, now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.dedupeWindow }
        let key = Self.dedupeKey(of: frame)
        if let i = pending.firstIndex(where: { $0.key == key }) {
            pending.remove(at: i)   // someone else already repeated it
            return false
        }
        guard seen[key] == nil, pending.count < Self.maxPending,
              let out = Self.rewrite(frame, myCall: myCall) else { return false }
        seen[key] = now
        pending.append(Pending(key: key, frame: out, frequency: frequency,
                               deadline: now.addingTimeInterval(Self.maxHold)))
        return true
    }

    // The next digipeat to transmit now: nil while the channel is busy or
    // nothing is queued. Stale ones are dropped.
    mutating func next(now: Date, channelClear: Bool) -> Pending? {
        pending.removeAll { $0.deadline <= now }
        guard channelClear, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func reset() {
        pending.removeAll()
        seen.removeAll()
    }
}
