import Foundation
import Testing
@testable import KV4P_HT

struct TxMeterGateTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func idleShowsMeter() {
        #expect(!TxMeterGate().suppressed(at: t0))
    }

    // The bug: RSSI spikes between the press and the firmware's TX echo.
    @Test func pttSuppressesBeforeTxEcho() {
        var g = TxMeterGate()
        g.setPTT(true, at: t0)
        #expect(g.suppressed(at: t0))
        g.deviceState(txActive: false, at: t0 + 0.05)
        #expect(g.suppressed(at: t0 + 0.05))
    }

    @Test func holdsAfterUnkey() {
        var g = TxMeterGate()
        g.setPTT(true, at: t0)
        g.deviceState(txActive: true, at: t0 + 0.1)
        g.setPTT(false, at: t0 + 2)
        // Firmware still reports TX until it applies the release.
        #expect(g.suppressed(at: t0 + 2.1))
        g.deviceState(txActive: false, at: t0 + 2.15)
        #expect(g.suppressed(at: t0 + 2.15 + TxMeterGate.unkeyHold - 0.01))
        #expect(!g.suppressed(at: t0 + 2.15 + TxMeterGate.unkeyHold))
        #expect(g.nextExpiry(after: t0 + 2.15) == t0 + 2.15 + TxMeterGate.unkeyHold)
    }

    @Test func holdsAfterPTTReleaseWithoutEcho() {
        var g = TxMeterGate()
        g.setPTT(true, at: t0)
        g.setPTT(false, at: t0 + 0.05)
        #expect(g.suppressed(at: t0 + 0.05 + TxMeterGate.unkeyHold - 0.01))
        #expect(!g.suppressed(at: t0 + 0.05 + TxMeterGate.unkeyHold))
    }

    // Repeated ptt:false pushes (any settings change) must not start a hold.
    @Test func pttUpWhileIdleDoesNotHold() {
        var g = TxMeterGate()
        g.setPTT(false, at: t0)
        #expect(!g.suppressed(at: t0))
        #expect(g.nextExpiry(after: t0) == nil)
    }

    @Test func packetSuppressesUntilFirmwareTxEnds() {
        var g = TxMeterGate()
        g.packetQueued(at: t0)
        #expect(g.suppressed(at: t0))
        // Sample before the firmware keys doesn't clear the queued packet.
        g.deviceState(txActive: false, at: t0 + 0.1)
        #expect(g.suppressed(at: t0 + 0.1))
        g.deviceState(txActive: true, at: t0 + 0.3)
        #expect(g.suppressed(at: t0 + 5))
        g.deviceState(txActive: false, at: t0 + 5)
        #expect(g.suppressed(at: t0 + 5.1))
        #expect(!g.suppressed(at: t0 + 5 + TxMeterGate.unkeyHold))
    }

    @Test func droppedPacketTimesOut() {
        var g = TxMeterGate()
        g.packetQueued(at: t0)
        #expect(g.nextExpiry(after: t0) == t0 + TxMeterGate.packetTimeout)
        #expect(g.suppressed(at: t0 + TxMeterGate.packetTimeout - 0.01))
        #expect(!g.suppressed(at: t0 + TxMeterGate.packetTimeout))
    }

    // Demo Radio echoes TX (mode 0) with rssi 0; gate follows the echo.
    @Test func demoRadioTxEcho() {
        var g = TxMeterGate()
        g.deviceState(txActive: true, at: t0)
        #expect(g.suppressed(at: t0 + 10))
        #expect(g.nextExpiry(after: t0) == nil)
        g.deviceState(txActive: false, at: t0 + 10)
        #expect(!g.suppressed(at: t0 + 10 + TxMeterGate.unkeyHold))
    }
}
