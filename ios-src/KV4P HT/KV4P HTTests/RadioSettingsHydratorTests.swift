import Testing
import Foundation
@testable import KV4P_HT

private func status(seq: UInt32, squelch: UInt8, flags: UInt16 = HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: seq, memoryId: -1, flags: flags,
        bw: DRA818_25K, freqTx: 146.52, freqRx: 146.52,
        ctcssTx: 0, squelch: squelch, ctcssRx: 0,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: 0, rssi: 100)
}

private func echo(_ d: HostDesiredState) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: d.sequence, memoryId: d.memoryId, flags: d.flags,
        bw: d.bw, freqTx: d.freqTx, freqRx: d.freqRx,
        ctcssTx: d.ctcssTx, squelch: d.squelch, ctcssRx: d.ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: 0, rssi: 100)
}

// RadioStore's squelch path in miniature: a controller fed by firmware
// status frames, the hydrator, and the slider value the user sees.
private final class SquelchHarness {
    let radio = RadioModuleController()
    var sent: [HostDesiredState] = []
    var hydrator = RadioSettingsHydrator()
    var ui: UInt8 = 0
    var seen: [UInt8] = []

    init(firmwareSquelch: UInt8) {
        radio.attachTransport { [unowned self] in sent.append($0) }
        radio.seedFromDeviceState(status(seq: 7, squelch: firmwareSquelch))
        radio.markTransportReady()
        radio.updateDeviceState(echo(sent[0]))
        hydrate(adoptAll: true)
    }

    // RadioStore.onDeviceState / onTransportReady.
    func frame(_ ds: DeviceStateFrame) {
        radio.updateDeviceState(ds)
        hydrate()
    }

    func hydrate(adoptAll: Bool = false) {
        if let v = hydrator.update(from: radio.desiredState, force: adoptAll).squelch { ui = v }
        seen.append(ui)
    }

    // Slider on main and PR #107: writes the store per drag step, sends on release.
    func drag(to level: UInt8) { ui = level; seen.append(ui) }
    func release() { radio.setSquelch(ui) }
}

struct RadioSettingsHydratorTests {

    // The reported bug: new → old → new after release, and the slider fighting
    // the finger mid-drag, because frames carried the old applied value.
    @Test func sliderNeverSnapsBack() {
        let h = SquelchHarness(firmwareSquelch: 2)
        let stale = status(seq: h.sent[0].sequence, squelch: 2)

        h.drag(to: 4)
        h.frame(stale)  // mid-drag status frame
        h.drag(to: 6)
        h.frame(stale)
        h.release()
        h.frame(stale)  // firmware hasn't applied yet
        h.frame(stale)  // ...and again (controller retries)
        h.frame(echo(h.sent.last!))
        h.frame(echo(h.sent.last!))

        #expect(h.seen == [2, 4, 4, 6, 6, 6, 6, 6, 6])
        #expect(h.radio.desiredSquelch == 6)
        #expect(h.radio.isAppliedStateInSync)
    }

    // Each step sent as it moves (VoiceOver adjustments in PR #107).
    @Test func perStepSendsNeverSnapBack() {
        let h = SquelchHarness(firmwareSquelch: 2)
        let stale = status(seq: h.sent[0].sequence, squelch: 2)
        for level: UInt8 in [3, 4, 5] {
            h.drag(to: level)
            h.release()
            h.frame(stale)
        }
        #expect(h.seen == [2, 3, 3, 4, 4, 5, 5])
    }

    // Another host (USB) changes squelch: the UI follows.
    @Test func followsNewerFirmwareState() {
        let h = SquelchHarness(firmwareSquelch: 2)
        h.frame(status(seq: h.sent[0].sequence + 5, squelch: 8))
        #expect(h.ui == 8)
    }

    // A new connection adopts the radio's settings even if they match what
    // was last hydrated (the user may have moved the slider while offline).
    @Test func adoptAllOnConnect() {
        var hydrator = RadioSettingsHydrator()
        let desired = HostDesiredState(
            sequence: 1, memoryId: -1, flags: HOST_STATE_HIGH_POWER | HOST_STATE_FILTER_LOW,
            bw: DRA818_12K5, freqTx: 146.52, freqRx: 146.52, ctcssTx: 0, squelch: 3, ctcssRx: 0)
        _ = hydrator.update(from: desired)
        #expect(hydrator.update(from: desired) == .init())
        #expect(hydrator.update(from: desired, force: true) == .init(
            squelch: 3, bandwidth: DRA818_12K5, highPower: true,
            filterHighPass: true, filterLowPass: false))
    }

    // Unrelated desired-state changes (PTT, tuning) don't touch settings.
    @Test func onlyChangedFieldsAreReturned() {
        var hydrator = RadioSettingsHydrator()
        var desired = HostDesiredState(
            sequence: 1, memoryId: -1, flags: HOST_STATE_HIGH_POWER,
            bw: DRA818_25K, freqTx: 146.52, freqRx: 146.52, ctcssTx: 0, squelch: 3, ctcssRx: 0)
        _ = hydrator.update(from: desired)
        desired.sequence = 2
        desired.freqRx = 147.0
        desired.flags |= HOST_STATE_PTT_REQUESTED
        #expect(hydrator.update(from: desired) == .init())
        desired.flags &= ~HOST_STATE_HIGH_POWER
        #expect(hydrator.update(from: desired) == .init(highPower: false))
    }
}
