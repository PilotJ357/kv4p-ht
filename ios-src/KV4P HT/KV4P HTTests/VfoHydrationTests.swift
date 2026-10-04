import Testing
import Foundation
@testable import KV4P_HT

private func appliedState(freqTx: Float, freqRx: Float, ctcssTx: UInt8) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: 1, memoryId: -1, flags: HOST_STATE_RADIO_CONFIG_VALID,
        bw: DRA818_25K, freqTx: freqTx, freqRx: freqRx,
        ctcssTx: ctcssTx, squelch: 2, ctcssRx: 0,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: 0, rssi: 100)
}

// Beaconing on the APRS frequency must not wipe the repeater offset/tone (#56).
struct VfoHydrationTests {

    @Test func repeaterStateHydratesOffsetAndTone() throws {
        let ds = appliedState(freqTx: 146.34, freqRx: 146.94, ctcssTx: 12)
        let vfo = try #require(RadioStore.appliedVfoConfig(ds, simplexSwitchActive: false))
        #expect(abs(vfo.offset - -0.6) < 0.0005)
        #expect(vfo.toneIndex == 12)
    }

    @Test func simplexBeaconStateIsIgnoredDuringSwitch() {
        let ds = appliedState(freqTx: 144.39, freqRx: 144.39, ctcssTx: 0)
        #expect(RadioStore.appliedVfoConfig(ds, simplexSwitchActive: true) == nil)
    }
}
