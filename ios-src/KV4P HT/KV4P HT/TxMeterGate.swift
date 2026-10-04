import Foundation

// Decides when the S-meter must read zero because the radio is (or just was)
// transmitting. The SA818 RSSI picks up our own carrier, and the firmware's
// TX echo (DeviceState mode 0) lags the PTT press, so gating on the echo
// alone lets the meter spike on key-up and flash a stale sample on unkey.
// Sources: local PTT request, firmware TX echo, and AX.25 frames handed to
// the firmware (which keys itself). Any of them ending starts a short hold.
nonisolated struct TxMeterGate {
    // Covers a stale RSSI sample still in flight after TX ends.
    static let unkeyHold: TimeInterval = 0.4
    // Upper bound on a queued packet that never shows up as TX (frame
    // dropped, or keyed and released between DeviceState samples).
    static let packetTimeout: TimeInterval = 3

    private(set) var pttHeld = false
    private(set) var txApplied = false
    private var packetQueuedAt: Date?
    private var txEndedAt: Date?

    mutating func setPTT(_ on: Bool, at now: Date) {
        if pttHeld && !on { txEndedAt = now }
        pttHeld = on
    }

    mutating func packetQueued(at now: Date) {
        packetQueuedAt = now
    }

    mutating func deviceState(txActive: Bool, at now: Date) {
        // Firmware took the packet; the TX echo tracks it from here.
        if txActive { packetQueuedAt = nil }
        if txApplied && !txActive { txEndedAt = now }
        txApplied = txActive
    }

    func suppressed(at now: Date) -> Bool {
        if pttHeld || txApplied { return true }
        return expiries.contains { now < $0 }
    }

    // Next moment suppressed(at:) can flip on its own, so the caller can
    // re-evaluate without polling. Nil while held open by PTT/TX or idle.
    func nextExpiry(after now: Date) -> Date? {
        expiries.filter { $0 > now }.min()
    }

    // Same Date arithmetic for both checks, so a timer fired at
    // nextExpiry sees suppressed(at:) flip exactly then.
    private var expiries: [Date] {
        [packetQueuedAt.map { $0 + Self.packetTimeout }, txEndedAt.map { $0 + Self.unkeyHold }]
            .compactMap { $0 }
    }
}
