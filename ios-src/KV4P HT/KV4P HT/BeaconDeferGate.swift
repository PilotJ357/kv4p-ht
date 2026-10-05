import Foundation

// Decides whether a position beacon goes out now or waits for the channel to
// go quiet. A fixed-frequency beacon retunes the radio (in the app when the
// current channel is out of band, in the firmware otherwise), so a scheduled
// beacon chops up whatever is being received — e.g. a continuous NOAA
// broadcast. With "Interrupt reception" off, a scheduled beacon that fires
// while squelch is open is held and retried until squelch closes. At most one
// beacon is ever pending; interval fires while one is held are dropped.
// "Beacon now" always sends immediately.
nonisolated struct BeaconDeferGate {
    // How often a held beacon re-checks squelch.
    static let retryInterval: TimeInterval = 20

    enum Trigger { case interval, retry, manual }
    enum Action: Equatable {
        case send
        case hold   // pending; re-check after retryInterval
        case skip   // nothing to do (already pending, or nothing pending)
    }

    private(set) var pending = false

    mutating func evaluate(_ trigger: Trigger, interruptReception: Bool,
                           squelched: Bool) -> Action {
        let mustWait = !interruptReception && !squelched
        switch trigger {
        case .manual:
            // A manual beacon satisfies any held one.
            pending = false
            return .send
        case .interval:
            if pending { return .skip }
            if mustWait {
                pending = true
                return .hold
            }
            return .send
        case .retry:
            guard pending else { return .skip }
            if mustWait { return .hold }
            pending = false
            return .send
        }
    }

    mutating func reset() {
        pending = false
    }
}
