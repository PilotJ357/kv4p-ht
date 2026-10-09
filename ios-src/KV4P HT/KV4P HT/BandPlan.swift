import Foundation

/// User-set amateur TX band edges in MHz (Android's min/max 2 m / 70 cm TX
/// freq settings). Plain bounds rather than ranges: persisted values aren't
/// trusted to be ordered, and `BandPlan` rejects an empty band.
nonisolated struct TxBandLimits: Equatable, Sendable {
    var vhfMin: Float
    var vhfMax: Float
    var uhfMin: Float
    var uhfMax: Float

    // Android's defaults (RadioAudioService min/max 2 m / 70 cm TX freq):
    // US 2 m and 70 cm amateur bands.
    static let defaults = TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 420, uhfMax: 450)

    /// `rfModuleType` from HELLO: 0 = VHF, anything else = UHF.
    func bounds(rfModuleType: UInt8) -> (min: Float, max: Float) {
        rfModuleType == 0 ? (vhfMin, vhfMax) : (uhfMin, uhfMax)
    }
}

/// Amateur-band transmit policy (port of Android's
/// `RadioAudioService.canTransmitOnFrequency`).
///
/// The module tunes well outside the amateur allocations (a VHF SA818 covers
/// ~134–174 MHz: marine, public safety, MURS…), and firmware gates PTT and
/// AX.25 TX only on the host's TX_ALLOWED flag, so this is what keeps
/// transmissions inside the band. Receiving anywhere the module tunes is fine.
nonisolated enum BandPlan {
    // Android's SettingsActivity dropdown values. ITU: 2 m is 144–146 in
    // Region 1, 144–148 in Regions 2 and 3; 70 cm is 430–440 everywhere, with
    // national extensions (US 420–450; Canada, Australia 430–450). Some
    // Region 3 countries stop at 146 on 2 m (Japan, India).
    static let vhfMinOptions: [Float] = [144]
    static let vhfMaxOptions: [Float] = [146, 148]
    static let uhfMinOptions: [Float] = [420, 430]
    static let uhfMaxOptions: [Float] = [440, 450]

    /// The module's TX band, clamped to its HELLO tuning range. nil (no TX)
    /// when the limits are unordered or miss the module's range entirely.
    static func txLimits(rfModuleType: UInt8, limits: TxBandLimits = .defaults,
                         moduleRange: ClosedRange<Float>? = nil) -> ClosedRange<Float>? {
        var (lo, hi) = limits.bounds(rfModuleType: rfModuleType)
        guard lo.isFinite, hi.isFinite else { return nil }
        if let moduleRange {
            lo = max(lo, moduleRange.lowerBound)
            hi = min(hi, moduleRange.upperBound)
        }
        return lo < hi ? lo...hi : nil
    }

    /// Keeps the whole emission, not just the carrier, inside the band edge.
    static func halfBandwidthMhz(_ bandwidth: UInt8) -> Float {
        (bandwidth == DRA818_25K ? 0.025 : 0.0125) / 2
    }

    static func canTransmit(onFrequency freq: Float, bandwidth: UInt8, rfModuleType: UInt8,
                            limits: TxBandLimits = .defaults,
                            moduleRange: ClosedRange<Float>? = nil) -> Bool {
        guard let band = txLimits(rfModuleType: rfModuleType, limits: limits,
                                  moduleRange: moduleRange) else { return false }
        let half = halfBandwidthMhz(bandwidth)
        return freq >= band.lowerBound + half && freq <= band.upperBound - half
    }
}

extension HelloFrame {
    /// Tuning range the module reports; nil if HELLO carries a bogus one.
    nonisolated var tuneRange: ClosedRange<Float>? {
        minFreq.isFinite && maxFreq.isFinite && minFreq < maxFreq ? minFreq...maxFreq : nil
    }
}
