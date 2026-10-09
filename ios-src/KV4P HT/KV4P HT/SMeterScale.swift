import Foundation

// Calibrated S-meter, same as Android (VanceVagell/kv4p-ht#432):
// S1–S9 at 6 dB/step, three +20 dB over-S9 bars, one RX overload bar.
// During TX the firmware puts TX audio level in the same RSSI field.
enum SMeterScale {
    static let maxBars = 13
    static let s9Bar = 9
    static let overloadBar = 13

    static let dbmPerRSSI = 1.2
    static let rssiDbmOffset = -160.8
    static let s1Dbm = -141.0
    static let s9Dbm = -93.0
    static let rxOverloadDbm = -30.0

    static func dbm(rssi: UInt8) -> Double {
        Double(rssi) * dbmPerRSSI + rssiDbmOffset
    }

    // 0 = below S1, 1–9 = S1–S9, 10–12 = S9+20/40/60, 13 = RX overload.
    static func bars(rssi: UInt8) -> Int {
        let dbm = dbm(rssi: rssi)
        if dbm > rxOverloadDbm { return overloadBar }
        if dbm < s1Dbm { return 0 }
        if dbm <= s9Dbm {
            return max(1, min(s9Bar, 1 + Int(((dbm - s1Dbm) / 6).rounded(.down))))
        }
        let over = Int(((dbm - s9Dbm) / 20).rounded(.down))
        return max(s9Bar, min(overloadBar - 1, s9Bar + over))
    }

    static func description(bars: Int, tx: Bool) -> String {
        if tx { return "TX audio level \(bars) of \(maxBars)" }
        switch bars {
        case 0:                    return "No signal"
        case overloadBar:          return "RX overload"
        case ...s9Bar:             return "S\(bars)"
        default:                   return "S9 plus \((bars - s9Bar) * 20) dB"
        }
    }
}
