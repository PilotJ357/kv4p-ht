import Foundation

/// Amateur-band transmit policy (port of Android's
/// `RadioAudioService.canTransmitOnFrequency`).
///
/// The module tunes well outside the amateur allocations (a VHF SA818 covers
/// ~134–174 MHz: marine, public safety, MURS…), and firmware gates PTT and
/// AX.25 TX only on the host's TX_ALLOWED flag, so this is what keeps
/// transmissions inside the band. Receiving anywhere the module tunes is fine.
nonisolated enum BandPlan {
    // Android's defaults (RadioAudioService min/max 2 m / 70 cm TX freq):
    // US 2 m and 70 cm amateur bands.
    static let vhfTxLimits: ClosedRange<Float> = 144.0...148.0
    static let uhfTxLimits: ClosedRange<Float> = 420.0...450.0

    /// `rfModuleType` from HELLO: 0 = VHF, anything else = UHF.
    static func txLimits(rfModuleType: UInt8) -> ClosedRange<Float> {
        rfModuleType == 0 ? vhfTxLimits : uhfTxLimits
    }

    /// Keeps the whole emission, not just the carrier, inside the band edge.
    static func halfBandwidthMhz(_ bandwidth: UInt8) -> Float {
        (bandwidth == DRA818_25K ? 0.025 : 0.0125) / 2
    }

    static func canTransmit(onFrequency freq: Float, bandwidth: UInt8, rfModuleType: UInt8) -> Bool {
        let limits = txLimits(rfModuleType: rfModuleType)
        let half = halfBandwidthMhz(bandwidth)
        return freq >= limits.lowerBound + half && freq <= limits.upperBound - half
    }
}
