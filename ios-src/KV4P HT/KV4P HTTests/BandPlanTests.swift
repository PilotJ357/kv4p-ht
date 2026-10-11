import Foundation
import Testing
@testable import KV4P_HT

private let vhf: UInt8 = 0
private let uhf: UInt8 = 1

private func canTx(_ freq: Float, _ bw: UInt8 = DRA818_25K, module: UInt8 = vhf,
                   limits: TxBandLimits = .defaults, moduleRange: ClosedRange<Float>? = nil) -> Bool {
    BandPlan.canTransmit(onFrequency: freq, bandwidth: bw, rfModuleType: module,
                         limits: limits, moduleRange: moduleRange)
}

private let region1 = TxBandLimits(vhfMin: 144, vhfMax: 146, uhfMin: 430, uhfMax: 440)

struct BandPlanTests {

    @Test func defaultsMatchAndroid() {
        #expect(BandPlan.txLimits(rfModuleType: vhf) == 144.0...148.0)
        #expect(BandPlan.txLimits(rfModuleType: uhf) == 420.0...450.0)
        #expect(TxBandLimits.defaults == TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 420, uhfMax: 450))
        #expect(BandPlan.halfBandwidthMhz(DRA818_25K) == 0.0125)
        #expect(BandPlan.halfBandwidthMhz(DRA818_12K5) == 0.00625)
    }

    @Test func inBand() {
        #expect(canTx(146.52))
        #expect(canTx(144.39))
        #expect(canTx(146.52, DRA818_12K5))
    }

    @Test func outOfBand() {
        #expect(!canTx(134.0))    // module minimum
        #expect(!canTx(151.82))   // MURS
        #expect(!canTx(156.8))    // marine ch 16
        #expect(!canTx(162.55))   // NOAA weather
        #expect(!canTx(0))
        #expect(!canTx(999.999))
    }

    @Test func wideEdgesKeepHalfChannelMargin() {
        #expect(!canTx(144.0))
        #expect(!canTx(144.012))
        #expect(canTx(144.0125))
        #expect(canTx(144.013))
        #expect(canTx(147.987))
        #expect(canTx(147.9875))
        #expect(!canTx(147.988))
        #expect(!canTx(148.0))
    }

    @Test func narrowEdgesKeepHalfChannelMargin() {
        #expect(!canTx(144.0, DRA818_12K5))
        #expect(!canTx(144.006, DRA818_12K5))
        #expect(canTx(144.00625, DRA818_12K5))
        #expect(canTx(144.007, DRA818_12K5))
        #expect(canTx(147.99375, DRA818_12K5))
        #expect(!canTx(147.994, DRA818_12K5))
        #expect(!canTx(148.0, DRA818_12K5))
        // Narrow clears an edge that wide doesn't.
        #expect(!canTx(147.99))
        #expect(canTx(147.99, DRA818_12K5))
    }

    @Test func repeaterOffsetCanPushTxOutOfBand() {
        #expect(canTx(146.94 - 0.6))    // typical 2 m repeater input
        #expect(!canTx(147.99 + 0.6))   // + offset past 148
        #expect(!canTx(144.2 - 0.6))    // − offset below 144
        #expect(!canTx(445.0 + 5.0, module: uhf))
        #expect(canTx(444.0 - 5.0, module: uhf))
    }

    @Test func uhfModule() {
        #expect(canTx(446.0, module: uhf))
        #expect(canTx(420.0125, module: uhf))
        #expect(canTx(449.9875, module: uhf))
        #expect(!canTx(420.0, module: uhf))
        #expect(!canTx(450.0, module: uhf))
        #expect(!canTx(462.5625, module: uhf))  // FRS/GMRS
        #expect(!canTx(146.52, module: uhf))
        #expect(!canTx(446.0, module: vhf))
    }

    @Test func presetLimits() {
        // 2 m: ITU Region 1 144–146, Regions 2/3 144–148 (Japan and India
        // 144–146). 70 cm: US 420–450; Canada, Australia 430–450; ITU 430–440.
        #expect(TxBandPlan.unitedStates.limits == .defaults)
        #expect(TxBandPlan.canadaAustralia.limits == TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 450))
        #expect(TxBandPlan.ituRegion23.limits == TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 440))
        #expect(TxBandPlan.ituRegion1.limits == region1)
        #expect(TxBandPlan.japanIndia.limits == region1)
        #expect(TxBandPlan.custom.limits == nil)
        // Rawvalues are persisted.
        #expect(Set(TxBandPlan.allCases.map(\.rawValue)).count == TxBandPlan.allCases.count)
        #expect(TxBandPlan(rawValue: "itu-r1") == .ituRegion1)
    }

    @Test func defaultPlanForRegion() {
        #expect(TxBandPlan.defaultPlan(forRegion: nil) == .unitedStates)
        #expect(TxBandPlan.defaultPlan(forRegion: "") == .unitedStates)
        for c in ["US", "us", "PR", "GU", "VI", "TT"] {
            #expect(TxBandPlan.defaultPlan(forRegion: c) == .unitedStates, "\(c)")
        }
        for c in ["CA", "AU"] {
            #expect(TxBandPlan.defaultPlan(forRegion: c) == .canadaAustralia, "\(c)")
        }
        for c in ["JP", "IN"] {
            #expect(TxBandPlan.defaultPlan(forRegion: c) == .japanIndia, "\(c)")
        }
        // Europe, Africa, Western and Central Asia, Mongolia.
        for c in ["GB", "DE", "RU", "UA", "ZA", "EG", "NG", "TR", "IL", "SA", "AE", "GE", "KZ", "MN"] {
            #expect(TxBandPlan.defaultPlan(forRegion: c) == .ituRegion1, "\(c)")
        }
        // Everything else: the ITU Region 2/3 allocation.
        for c in ["NZ", "CN", "KR", "TH", "BR", "MX", "AR", "IR"] {
            #expect(TxBandPlan.defaultPlan(forRegion: c) == .ituRegion23, "\(c)")
        }
    }

    @Test func customBandValidation() {
        let vhf = BandPlan.nominalVhfRange
        #expect(BandPlan.isValidCustomBand(min: 144, max: 146, moduleRange: vhf))
        #expect(BandPlan.isValidCustomBand(min: 134, max: 174, moduleRange: vhf))  // module edges
        #expect(BandPlan.isValidCustomBand(min: 144.5, max: 145.5, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: 146, max: 144, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: 146, max: 146, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: 133.9, max: 146, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: 144, max: 174.1, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: 430, max: 440, moduleRange: vhf))
        #expect(!BandPlan.isValidCustomBand(min: .nan, max: 146, moduleRange: vhf))
        #expect(BandPlan.isValidCustomBand(min: 430, max: 440, moduleRange: BandPlan.nominalUhfRange))
        #expect(BandPlan.nominalModuleRange(rfModuleType: 0) == vhf)
        #expect(BandPlan.nominalModuleRange(rfModuleType: 1) == BandPlan.nominalUhfRange)
    }

    @Test func region1Limits() {
        #expect(canTx(145.5, limits: region1))
        #expect(canTx(145.9875, limits: region1))
        #expect(!canTx(145.988, limits: region1))
        #expect(!canTx(146.52, limits: region1))   // US calling freq
        #expect(!canTx(147.0, limits: region1))
        #expect(canTx(433.5, module: uhf, limits: region1))
        #expect(canTx(430.0125, module: uhf, limits: region1))
        #expect(!canTx(430.0, module: uhf, limits: region1))
        #expect(!canTx(425.0, module: uhf, limits: region1))
        #expect(!canTx(446.0, module: uhf, limits: region1))  // PMR446
        #expect(BandPlan.txLimits(rfModuleType: vhf, limits: region1) == 144.0...146.0)
        #expect(BandPlan.txLimits(rfModuleType: uhf, limits: region1) == 430.0...440.0)
    }

    @Test func unorderedLimitsBlockTx() {
        let flipped = TxBandLimits(vhfMin: 148, vhfMax: 144, uhfMin: 440, uhfMax: 440)
        #expect(BandPlan.txLimits(rfModuleType: vhf, limits: flipped) == nil)
        #expect(BandPlan.txLimits(rfModuleType: uhf, limits: flipped) == nil)
        #expect(!canTx(146.0, limits: flipped))
        #expect(!canTx(440.0, module: uhf, limits: flipped))
        let nan = TxBandLimits(vhfMin: .nan, vhfMax: 148, uhfMin: 420, uhfMax: .infinity)
        #expect(!canTx(146.0, limits: nan))
        #expect(!canTx(446.0, module: uhf, limits: nan))
    }

    @Test func limitsClampToModuleRange() {
        // A module that stops short of the band edge narrows the TX band.
        #expect(BandPlan.txLimits(rfModuleType: vhf, moduleRange: 134...147) == 144.0...147.0)
        #expect(canTx(146.9875, moduleRange: 134...147))
        #expect(!canTx(147.5, moduleRange: 134...147))
        #expect(BandPlan.txLimits(rfModuleType: uhf, moduleRange: 425...480) == 425.0...450.0)
        #expect(!canTx(424.0, module: uhf, moduleRange: 425...480))
        // Band entirely outside the module's range: no TX.
        #expect(BandPlan.txLimits(rfModuleType: vhf, moduleRange: 150...174) == nil)
        #expect(!canTx(146.0, moduleRange: 150...174))
        // Real SA818 ranges don't trim the defaults.
        #expect(BandPlan.txLimits(rfModuleType: vhf, moduleRange: 134...174) == 144.0...148.0)
        #expect(BandPlan.txLimits(rfModuleType: uhf, moduleRange: 400...480) == 420.0...450.0)
    }

    private func reason(_ freq: Float, _ bw: UInt8 = DRA818_25K, module: UInt8 = vhf,
                        limits: TxBandLimits = .defaults,
                        moduleRange: ClosedRange<Float>? = nil) -> TxBlockReason? {
        BandPlan.txBlockReason(onFrequency: freq, bandwidth: bw, rfModuleType: module,
                               limits: limits, moduleRange: moduleRange)
    }

    @Test func blockReasons() {
        #expect(reason(146.52) == nil)
        #expect(reason(146.52, limits: region1) == .outsideBand(min: 144, max: 146))
        #expect(reason(162.55) == .outsideBand(min: 144, max: 148))
        #expect(reason(462.5625, module: uhf) == .outsideBand(min: 420, max: 450))
        #expect(reason(147.995) == .bandEdge(148))
        #expect(reason(144.005, DRA818_12K5) == .bandEdge(144))
        #expect(reason(146.0, moduleRange: 150...174) == .noTxBand)
        #expect(reason(146.0, limits: TxBandLimits(vhfMin: 148, vhfMax: 144, uhfMin: 420, uhfMax: 450)) == .noTxBand)
        // Inside the plan but past what the module covers.
        #expect(reason(147.5, moduleRange: 134...147) == .outsideRadioRange(min: 144, max: 147))
        #expect(reason(146.9995, moduleRange: 134...147) == .bandEdge(147))
        // Agrees with canTransmit.
        for f: Float in [143.99, 144.0, 144.01, 146.52, 147.99, 148.0, 151.82, 162.55] {
            for bw in [DRA818_25K, DRA818_12K5] {
                #expect((reason(f, bw) == nil) == canTx(f, bw), "\(f) \(bw)")
            }
        }
    }

    @Test func blockReasonRangesDontWrap() {
        let m = TxBlockReason.outsideBand(min: 144, max: 146).message(
            txFreq: 146.52, rxFreq: 146.52, planLabel: "Japan, India",
            moduleRange: nil, narrowFits: false)
        #expect(m.hasSuffix("(Japan, India: 144\u{2060}–\u{2060}146\u{00A0}MHz)"))
    }

    @Test func blockReasonFixableInSettings() {
        #expect(TxBlockReason.noTxBand.isBandPlan)
        #expect(TxBlockReason.outsideBand(min: 144, max: 146).isBandPlan)
        #expect(!TxBlockReason.outsideRadioRange(min: 144, max: 147).isBandPlan)
        #expect(!TxBlockReason.bandEdge(148).isBandPlan)
    }

    @Test func blockReasonMessages() {
        func msg(_ r: TxBlockReason, tx: Float, rx: Float? = nil, plan: String = "United States",
                 range: ClosedRange<Float>? = 134...174, narrowFits: Bool = false) -> String {
            r.message(txFreq: tx, rxFreq: rx ?? tx, planLabel: plan,
                      moduleRange: range, narrowFits: narrowFits)
                .replacingOccurrences(of: "\u{2060}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        #expect(msg(.outsideBand(min: 144, max: 146), tx: 146.52, plan: "Japan, India")
                == "Outside your TX band plan (Japan, India: 144–146 MHz)")
        #expect(msg(.outsideBand(min: 144, max: 148), tx: 148.6, rx: 148.0)
                == "Offset puts TX on 148.600, outside your band plan (United States: 144–148 MHz)")
        #expect(msg(.outsideBand(min: 430, max: 440), tx: 446.0, plan: "Custom")
                == "Outside your TX band plan (Custom: 430–440 MHz)")
        #expect(msg(.bandEdge(148), tx: 147.995)
                == "Signal would spill past the 148 MHz band edge")
        #expect(msg(.bandEdge(148), tx: 147.99, narrowFits: true)
                == "Signal would spill past the 148 MHz band edge; try 12.5 kHz bandwidth")
        #expect(msg(.bandEdge(144), tx: 144.005, rx: 144.605)
                == "TX on 144.005 would spill past the 144 MHz band edge")
        #expect(msg(.noTxBand, tx: 146.0, range: 150...174)
                == "Your TX band plan doesn't overlap this radio's 150–174 MHz range")
        #expect(msg(.noTxBand, tx: 146.0, range: nil)
                == "Your TX band plan has no transmit range for this radio")
        #expect(msg(.outsideRadioRange(min: 144, max: 147), tx: 147.5)
                == "Beyond this radio's 144–147 MHz transmit range")
        #expect(msg(.outsideRadioRange(min: 144, max: 147), tx: 147.5, rx: 146.9)
                == "Offset puts TX on 147.500, beyond this radio's 144–147 MHz transmit range")
        // Fractional edges keep their decimals.
        #expect(msg(.outsideBand(min: 144.025, max: 145.8), tx: 146.0, plan: "Custom")
                == "Outside your TX band plan (Custom: 144.025–145.8 MHz)")
    }

    @Test func helloTuneRange() {
        let ds = DeviceStateFrame(
            appliedSequence: 0, memoryId: -1, flags: 0, bw: DRA818_25K, freqTx: 0, freqRx: 0,
            ctcssTx: 0, squelch: 0, ctcssRx: 0, radioModuleStatus: RADIO_STATUS_FOUND,
            mode: 1, lastError: 0, rssi: 0)
        func hello(_ lo: Float, _ hi: Float) -> HelloFrame {
            HelloFrame(firmwareVersion: 17, radioModuleFound: true, windowSize: 1024,
                       rfModuleType: 0, minFreq: lo, maxFreq: hi, features: 0, deviceState: ds)
        }
        #expect(hello(134, 174).tuneRange == 134.0...174.0)
        #expect(hello(0, 0).tuneRange == nil)
        #expect(hello(174, 134).tuneRange == nil)
        #expect(hello(.nan, 174).tuneRange == nil)
    }
}
