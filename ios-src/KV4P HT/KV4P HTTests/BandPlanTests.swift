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

    @Test func androidOptionsIncludeDefaultsAndOrder() {
        let d = TxBandLimits.defaults
        #expect(BandPlan.vhfMinOptions.contains(d.vhfMin))
        #expect(BandPlan.vhfMaxOptions.contains(d.vhfMax))
        #expect(BandPlan.uhfMinOptions.contains(d.uhfMin))
        #expect(BandPlan.uhfMaxOptions.contains(d.uhfMax))
        // Every min/max pick is a valid band.
        for lo in BandPlan.vhfMinOptions { for hi in BandPlan.vhfMaxOptions { #expect(lo < hi) } }
        for lo in BandPlan.uhfMinOptions { for hi in BandPlan.uhfMaxOptions { #expect(lo < hi) } }
    }

    @Test func optionsCoverNationalPlans() {
        // 2 m: ITU Region 1 144–146, Regions 2/3 144–148 (Japan and India
        // 144–146). 70 cm: US 420–450; Canada, Australia 430–450;
        // Region 1, Japan, India, NZ 430–440.
        let plans: [(String, TxBandLimits)] = [
            ("US", TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 420, uhfMax: 450)),
            ("Canada/Australia", TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 450)),
            ("NZ", TxBandLimits(vhfMin: 144, vhfMax: 148, uhfMin: 430, uhfMax: 440)),
            ("Region 1/Japan/India", region1),
        ]
        for (name, p) in plans {
            #expect(BandPlan.vhfMinOptions.contains(p.vhfMin), "\(name)")
            #expect(BandPlan.vhfMaxOptions.contains(p.vhfMax), "\(name)")
            #expect(BandPlan.uhfMinOptions.contains(p.uhfMin), "\(name)")
            #expect(BandPlan.uhfMaxOptions.contains(p.uhfMax), "\(name)")
        }
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
