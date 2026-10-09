import Testing
@testable import KV4P_HT

struct SMeterScaleTests {
    // Same vector as Android ProtocolKissTest.sMeterUsesCalibratedRssiRange.
    @Test(arguments: [
        (0, 0), (16, 0), (17, 1), (22, 2), (56, 8), (57, 9), (64, 9), (65, 9),
        (74, 10), (82, 10), (90, 11), (99, 11), (107, 12), (109, 12), (110, 13), (255, 13),
    ])
    func matchesAndroidCalibration(rssi: Int, bars: Int) {
        #expect(SMeterScale.bars(rssi: UInt8(rssi)) == bars)
    }

    @Test func monotonic() {
        var last = 0
        for r in 0...255 {
            let b = SMeterScale.bars(rssi: UInt8(r))
            #expect(b >= last)
            last = b
        }
    }

    @Test func descriptions() {
        #expect(SMeterScale.description(bars: 0, tx: false) == "No signal")
        #expect(SMeterScale.description(bars: 7, tx: false) == "S7")
        #expect(SMeterScale.description(bars: 11, tx: false) == "S9 plus 40 dB")
        #expect(SMeterScale.description(bars: 13, tx: false) == "RX overload")
        #expect(SMeterScale.description(bars: 11, tx: true) == "TX audio level 11 of 13")
    }
}
