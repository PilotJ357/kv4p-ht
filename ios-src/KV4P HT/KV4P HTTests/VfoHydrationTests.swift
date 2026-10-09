import Testing
import Foundation
@testable import KV4P_HT

private func appliedState(freqTx: Float, freqRx: Float, ctcssTx: UInt8, ctcssRx: UInt8 = 0) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: 1, memoryId: -1, flags: HOST_STATE_RADIO_CONFIG_VALID,
        bw: DRA818_25K, freqTx: freqTx, freqRx: freqRx,
        ctcssTx: ctcssTx, squelch: 2, ctcssRx: ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: 0, rssi: 100)
}

// Beaconing on the APRS frequency must not wipe the repeater offset/tone (#56).
struct VfoHydrationTests {

    @Test func repeaterStateHydratesOffsetAndTone() throws {
        let ds = appliedState(freqTx: 146.34, freqRx: 146.94, ctcssTx: 12, ctcssRx: 14)
        let vfo = try #require(RadioStore.appliedVfoConfig(ds, simplexSwitchActive: false))
        #expect(abs(vfo.offset - -0.6) < 0.0005)
        #expect(vfo.toneIndex == 12)
        #expect(vfo.rxToneIndex == 14)
    }

    @Test func simplexBeaconStateIsIgnoredDuringSwitch() {
        let ds = appliedState(freqTx: 144.39, freqRx: 144.39, ctcssTx: 0)
        #expect(RadioStore.appliedVfoConfig(ds, simplexSwitchActive: true) == nil)
    }

    // #124: pill shows RX tone squelch alongside the TX tone.
    @Test func toneStringCoversTxRxCombos() {
        #expect(RadioStore.toneString(tx: 0, rx: 0) == "Off")
        #expect(RadioStore.toneString(tx: 12, rx: 0) == "PL 100.0")
        #expect(RadioStore.toneString(tx: 12, rx: 12) == "TSQL 100.0")
        #expect(RadioStore.toneString(tx: 12, rx: 14) == "100.0/107.2")
        #expect(RadioStore.toneString(tx: 0, rx: 12) == "Off/100.0")
    }
}
