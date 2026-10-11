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

/// Amateur TX band plan presets. ITU: 2 m is 144–146 in Region 1 and 144–148
/// in Regions 2 and 3; 70 cm is 430–440 everywhere, with national extensions
/// (US 420–450; Canada, Australia 430–450 since 2013). Japan and India stop
/// at 146 on 2 m. Android offers the same edges as four separate dropdowns.
nonisolated enum TxBandPlan: String, CaseIterable, Identifiable, Sendable {
    case unitedStates = "us"
    case canadaAustralia = "ca-au"
    case ituRegion23 = "itu-r23"
    case ituRegion1 = "itu-r1"
    case japanIndia = "jp-in"
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unitedStates:    "United States"
        case .canadaAustralia: "Canada, Australia"
        case .ituRegion23:     "Other Americas, Asia, Pacific"
        case .ituRegion1:      "Europe, Africa, Middle East"
        case .japanIndia:      "Japan, India"
        case .custom:          "Custom"
        }
    }

    /// nil for `.custom`, whose edges the user enters.
    var limits: TxBandLimits? {
        switch self {
        case .unitedStates:    .defaults
        case .canadaAustralia: TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 450)
        case .ituRegion23:     TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 440)
        case .ituRegion1, .japanIndia:
                               TxBandLimits(vhfMin: 144, vhfMax: 146, uhfMin: 430, uhfMax: 440)
        case .custom:          nil
        }
    }

    // US territories, plus Trinidad and Tobago (also 420–450).
    private static let usPlanRegions: Set<String> = ["US", "PR", "GU", "VI", "AS", "MP", "UM", "TT"]

    /// First-launch plan for the device region (ISO 3166 code). ITU Region 1
    /// is Europe, Africa, Western and Central Asia, and Mongolia; any other
    /// region gets the ITU Region 2/3 allocation, which is narrower than the
    /// US plan on 70 cm. No region: the US plan, like Android.
    static func defaultPlan(forRegion code: String?) -> TxBandPlan {
        guard let code = code?.uppercased(), !code.isEmpty else { return .unitedStates }
        switch code {
        case let c where usPlanRegions.contains(c): return .unitedStates
        case "CA", "AU": return .canadaAustralia
        case "JP", "IN": return .japanIndia
        case "MN": return .ituRegion1
        default: break
        }
        let region = Locale.Region(code)
        let continent = region.continent?.identifier
        let subregion = region.containingRegion?.identifier
        if continent == "150" || continent == "002"            // Europe, Africa
            || subregion == "145" || subregion == "143" {  // Western, Central Asia
            return .ituRegion1
        }
        return .ituRegion23
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
    // SA818 tuning ranges, for checking custom limits before HELLO says
    // which module (and exact range) is attached.
    static let nominalVhfRange: ClosedRange<Float> = 134...174
    static let nominalUhfRange: ClosedRange<Float> = 400...480

    static func nominalModuleRange(rfModuleType: UInt8) -> ClosedRange<Float> {
        rfModuleType == 0 ? nominalVhfRange : nominalUhfRange
    }

    /// Custom TX edges must be ordered and inside what the module can tune.
    static func isValidCustomBand(min: Float, max: Float, moduleRange: ClosedRange<Float>) -> Bool {
        min.isFinite && max.isFinite && min < max
            && moduleRange.contains(min) && moduleRange.contains(max)
    }

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
        txBlockReason(onFrequency: freq, bandwidth: bandwidth, rfModuleType: rfModuleType,
                      limits: limits, moduleRange: moduleRange) == nil
    }

    /// Why `canTransmit` refuses `freq`; nil when TX is allowed.
    static func txBlockReason(onFrequency freq: Float, bandwidth: UInt8, rfModuleType: UInt8,
                              limits: TxBandLimits = .defaults,
                              moduleRange: ClosedRange<Float>? = nil) -> TxBlockReason? {
        guard let band = txLimits(rfModuleType: rfModuleType, limits: limits,
                                  moduleRange: moduleRange) else { return .noTxBand }
        guard band.contains(freq) else {
            // Inside the plan but past the module's range is the radio's
            // limit, not the plan's (tuning there is normally refused anyway).
            let plan = limits.bounds(rfModuleType: rfModuleType)
            return freq >= plan.min && freq <= plan.max
                ? .outsideRadioRange(min: band.lowerBound, max: band.upperBound)
                : .outsideBand(min: plan.min, max: plan.max)
        }
        let half = halfBandwidthMhz(bandwidth)
        if freq < band.lowerBound + half { return .bandEdge(band.lowerBound) }
        if freq > band.upperBound - half { return .bandEdge(band.upperBound) }
        return nil
    }
}

/// Why a TX frequency is receive only (RX ONLY on the PTT button).
nonisolated enum TxBlockReason: Equatable, Sendable {
    /// The TX band limits are empty or miss the module's tuning range, so
    /// nothing the module tunes is transmittable.
    case noTxBand
    /// Carrier outside the band plan's edges (MHz).
    case outsideBand(min: Float, max: Float)
    /// Carrier inside the plan but outside the part of it the module can
    /// transmit on (MHz).
    case outsideRadioRange(min: Float, max: Float)
    /// Carrier inside the band, but the emission at this bandwidth would
    /// cross the given edge (MHz).
    case bandEdge(Float)

    /// The user can fix it by picking another TX band plan.
    var isBandPlan: Bool {
        switch self {
        case .noTxBand, .outsideBand: true
        case .outsideRadioRange, .bandEdge: false
        }
    }

    /// One-line explanation under the RX ONLY button. `txFreq` differs from
    /// `rxFreq` when a repeater offset is set; `narrowFits` says 12.5 kHz
    /// bandwidth would clear a band edge.
    func message(txFreq: Float, rxFreq: Float, planLabel: String,
                 moduleRange: ClosedRange<Float>?, narrowFits: Bool) -> String {
        let offsetTx = abs(txFreq - rxFreq) >= 0.0005
        let tx = String(format: "%.3f", txFreq)
        switch self {
        case .noTxBand:
            guard let r = moduleRange else {
                return "Your TX band plan has no transmit range for this radio"
            }
            return "Your TX band plan doesn't overlap this radio's \(Self.mhz(r.lowerBound, r.upperBound)) range"
        case .outsideBand(let lo, let hi):
            let plan = "\(planLabel): \(Self.mhz(lo, hi))"
            return offsetTx
                ? "Offset puts TX on \(tx), outside your band plan (\(plan))"
                : "Outside your TX band plan (\(plan))"
        case .outsideRadioRange(let lo, let hi):
            let range = Self.mhz(lo, hi)
            return offsetTx
                ? "Offset puts TX on \(tx), beyond this radio's \(range) transmit range"
                : "Beyond this radio's \(range) transmit range"
        case .bandEdge(let edge):
            let what = offsetTx ? "TX on \(tx)" : "Signal"
            let base = "\(what) would spill past the \(Self.mhz(edge)) band edge"
            return narrowFits ? base + "; try 12.5 kHz bandwidth" : base
        }
    }

    // "144 MHz", "430.5 MHz": no trailing zeros. A no-break space and word
    // joiners keep a value or range from wrapping mid-way.
    private static func mhz(_ f: Float) -> String {
        String(format: "%g\u{00A0}MHz", f)
    }

    private static func mhz(_ lo: Float, _ hi: Float) -> String {
        String(format: "%g\u{2060}–\u{2060}%g\u{00A0}MHz", lo, hi)
    }
}

extension HelloFrame {
    /// Tuning range the module reports; nil if HELLO carries a bogus one.
    nonisolated var tuneRange: ClosedRange<Float>? {
        minFreq.isFinite && maxFreq.isFinite && minFreq < maxFreq ? minFreq...maxFreq : nil
    }
}
