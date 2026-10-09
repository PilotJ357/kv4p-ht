import Foundation

// Decides when scan leaves a channel (#125). Firmware resets its soft
// squelch closed on every retune, and the noise detector needs ~250 ms of
// carrier before it can open, so a "squelched" flag right after a tune says
// nothing about the channel. Scan used to step every 250 ms on that flag and
// never stopped on anything. The gate waits for the radio to report the new
// RX frequency, then gives squelch `dwell` to open. Activity holds the
// channel until it has been quiet for `resumeDelay`. Clock-free: the caller
// polls update(…).
nonisolated struct ScanDwellGate {
    enum Decision: Equatable {
        // Waiting for the tune to land or for squelch to get a chance.
        case wait
        // Activity on this channel (now or within resumeDelay).
        case hold
        // Move to the next channel.
        case advance
    }

    // Time after the tune is confirmed for squelch to open.
    var dwell: TimeInterval = 0.5
    // Quiet time after activity before scan resumes, so replies are heard.
    var resumeDelay: TimeInterval = 2.0
    // Give up on a tune the radio never confirms instead of stalling scan.
    var applyTimeout: TimeInterval = 2.0
    // Open flags this soon after the confirm predate the squelch reset:
    // the reconcile frame carries the previous channel's squelch state.
    var staleOpenWindow: TimeInterval = 0.2

    private(set) var target: Float?
    private var tunedAt: Date?
    private var appliedAt: Date?
    private var lastActivityAt: Date?

    var isHolding: Bool { lastActivityAt != nil }

    mutating func tuned(to rxFreq: Float, now: Date) {
        target = rxFreq
        tunedAt = now
        appliedAt = nil
        lastActivityAt = nil
    }

    mutating func reset() {
        target = nil
        tunedAt = nil
        appliedAt = nil
        lastActivityAt = nil
    }

    // `active`: squelch open or transmitting on this channel.
    mutating func update(appliedRxFreq: Float?, active: Bool, now: Date) -> Decision {
        guard let target, let tunedAt else { return .wait }
        let applied: Date
        if let appliedAt {
            applied = appliedAt
        } else {
            guard let freq = appliedRxFreq, abs(freq - target) < 0.0005 else {
                return now.timeIntervalSince(tunedAt) >= applyTimeout ? .advance : .wait
            }
            appliedAt = now
            applied = now
        }
        if active, now.timeIntervalSince(applied) >= staleOpenWindow {
            lastActivityAt = now
            return .hold
        }
        if let lastActivityAt {
            return now.timeIntervalSince(lastActivityAt) >= resumeDelay ? .advance : .hold
        }
        return now.timeIntervalSince(applied) >= dwell ? .advance : .wait
    }
}
