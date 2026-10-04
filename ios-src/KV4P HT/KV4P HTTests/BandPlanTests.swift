import Testing
@testable import KV4P_HT

private let vhf: UInt8 = 0
private let uhf: UInt8 = 1

private func canTx(_ freq: Float, _ bw: UInt8 = DRA818_25K, module: UInt8 = vhf) -> Bool {
    BandPlan.canTransmit(onFrequency: freq, bandwidth: bw, rfModuleType: module)
}

struct BandPlanTests {

    @Test func defaultsMatchAndroid() {
        #expect(BandPlan.txLimits(rfModuleType: vhf) == 144.0...148.0)
        #expect(BandPlan.txLimits(rfModuleType: uhf) == 420.0...450.0)
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
}
