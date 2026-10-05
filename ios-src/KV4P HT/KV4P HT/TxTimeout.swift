import Foundation

// Transmit time-out timer (TOT) for voice PTT, like most HTs: a stuck or
// forgotten sticky PTT unkeys on its own instead of holding the carrier
// (and the live mic) indefinitely. APRS/AX.25 bursts don't go through here.
nonisolated enum TxTimeout {
    // Seconds; 0 = off. Default 3 min.
    static let options: [Int] = [60, 120, 180, 300, 600, 0]
    static let defaultSeconds = 180
    // How long before the cut the warning shows.
    static let warningLead: TimeInterval = 10

    enum Phase: Equatable {
        case ok
        case warning(remaining: Int)
        case expired
    }

    static func phase(elapsed: TimeInterval, limit: Int) -> Phase {
        guard limit > 0 else { return .ok }
        let remaining = TimeInterval(limit) - elapsed
        if remaining <= 0 { return .expired }
        if remaining <= warningLead { return .warning(remaining: Int(remaining.rounded(.up))) }
        return .ok
    }

    static func label(_ seconds: Int) -> String {
        seconds == 0 ? "Off" : "\(seconds / 60) min"
    }
}
