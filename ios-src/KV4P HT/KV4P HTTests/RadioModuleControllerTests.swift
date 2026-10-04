import Testing
import Foundation
@testable import KV4P_HT

private final class SentFrames {
    var frames: [HostDesiredState] = []
}

private func makeDeviceState(
    seq: UInt32 = 7,
    flags: UInt16 = HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED,
    bw: UInt8 = DRA818_25K,
    freqTx: Float = 146.52,
    freqRx: Float = 146.52,
    ctcssTx: UInt8 = 0,
    squelch: UInt8 = 2,
    ctcssRx: UInt8 = 0,
    lastError: UInt8 = 0
) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: seq, memoryId: -1, flags: flags,
        bw: bw, freqTx: freqTx, freqRx: freqRx,
        ctcssTx: ctcssTx, squelch: squelch, ctcssRx: ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: lastError, rssi: 100)
}

// Firmware echo of a desired state the host sent (i.e. firmware applied it).
private func echo(_ d: HostDesiredState, appliedSequence: UInt32? = nil, lastError: UInt8 = 0) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: appliedSequence ?? d.sequence, memoryId: d.memoryId, flags: d.flags,
        bw: d.bw, freqTx: d.freqTx, freqRx: d.freqRx,
        ctcssTx: d.ctcssTx, squelch: d.squelch, ctcssRx: d.ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: lastError, rssi: 100)
}

private func makeHello(rfModuleType: UInt8, deviceState: DeviceStateFrame) -> HelloFrame {
    HelloFrame(
        firmwareVersion: 17, radioModuleFound: true, windowSize: 1024,
        rfModuleType: rfModuleType,
        minFreq: rfModuleType == 0 ? 134 : 400, maxFreq: rfModuleType == 0 ? 174 : 480,
        features: 0, deviceState: deviceState)
}

// Controller seeded from `seed`, transport attached and ready. The post-seed
// flush always emits one frame (the STATUS_REPORTS re-enable), so tests start
// from sent.frames.count == 1. `rfModuleType` seeds a HELLO (band plan).
private func makeReadyController(
    seed: DeviceStateFrame = makeDeviceState(),
    rfModuleType: UInt8? = nil
) -> (RadioModuleController, SentFrames) {
    let controller = RadioModuleController()
    let sent = SentFrames()
    controller.attachTransport { sent.frames.append($0) }
    if let rfModuleType {
        controller.seedFirmwareInfo(makeHello(rfModuleType: rfModuleType, deviceState: seed))
    }
    controller.seedFromDeviceState(seed)
    controller.markTransportReady()
    return (controller, sent)
}

private func hasFlag(_ state: HostDesiredState?, _ flag: UInt16) -> Bool {
    state.map { $0.flags & flag != 0 } ?? false
}

struct RadioModuleControllerTests {

    @Test func seedsDesiredStateFromDeviceState() {
        let controller = RadioModuleController()
        let seed = makeDeviceState(seq: 42, freqTx: 147.0, freqRx: 146.4, ctcssTx: 5, squelch: 3)
        controller.seedFromDeviceState(seed)

        let desired = controller.desiredState
        #expect(desired.sequence == 42)
        #expect(desired.freqTx == 147.0)
        #expect(desired.freqRx == 146.4)
        #expect(desired.ctcssTx == 5)
        #expect(desired.squelch == 3)
        #expect(desired.bw == DRA818_25K)
        // PTT/RX_AUDIO never seeded on; status reports forced on.
        #expect(desired.flags & HOST_STATE_PTT_REQUESTED == 0)
        #expect(desired.flags & HOST_STATE_RX_AUDIO_OPEN == 0)
        #expect(desired.flags & HOST_STATE_ENABLE_STATUS_REPORTS != 0)
        #expect(desired.flags & HOST_STATE_RADIO_CONFIG_VALID != 0)
    }

    @Test func seedWithoutRadioConfigFallsBackToDefaults() {
        let controller = RadioModuleController()
        controller.seedFromDeviceState(makeDeviceState(seq: 9, flags: 0, freqTx: 0, freqRx: 0))

        let desired = controller.desiredState
        #expect(desired.sequence == 9)
        #expect(desired.flags & HOST_STATE_RADIO_CONFIG_VALID == 0)
        #expect(desired.bw == DRA818_25K)
    }

    @Test func seedFlushEnablesStatusReportsOnce() {
        let (_, sent) = makeReadyController()
        #expect(sent.frames.count == 1)
        #expect(sent.frames[0].flags & HOST_STATE_ENABLE_STATUS_REPORTS != 0)
    }

    @Test func sendsOnlyOnChange() {
        let seed = makeDeviceState(squelch: 2)
        let (controller, sent) = makeReadyController(seed: seed)
        #expect(sent.frames.count == 1)

        controller.setSquelch(2)  // no-op: same value
        #expect(sent.frames.count == 1)

        controller.setSquelch(5)
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].squelch == 5)
    }

    @Test func batchedUpdateEmitsSingleFrame() {
        let (controller, sent) = makeReadyController()
        controller.beginUpdate()
        controller.setRxFrequency(147.105)
        controller.setTxFrequency(147.705)
        controller.setSquelch(4)
        #expect(sent.frames.count == 1)  // nothing sent mid-batch
        controller.endUpdate()
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].freqRx == 147.105)
        #expect(sent.frames[1].freqTx == 147.705)
        #expect(sent.frames[1].squelch == 4)
    }

    @Test func sequenceIncrementsPerSend() {
        let seed = makeDeviceState(seq: 10)
        let (controller, sent) = makeReadyController(seed: seed)
        #expect(sent.frames[0].sequence == 11)

        controller.setSquelch(5)
        #expect(sent.frames[1].sequence == 12)

        controller.setRxFrequency(147.0)
        #expect(sent.frames[2].sequence == 13)
    }

    @Test func nextSendUsesLatestAppliedDeviceSequence() {
        let seed = makeDeviceState(seq: 10)
        let (controller, sent) = makeReadyController(seed: seed)
        controller.updateDeviceState(echo(sent.frames[0], appliedSequence: 25))
        #expect(sent.frames.count == 1)
        #expect(controller.isAppliedStateInSync)

        controller.setSquelch(5)
        #expect(sent.frames[1].sequence == 26)
    }

    @Test func aheadDeviceSequenceAdoptsDeviceStateWithoutSending() {
        let seed = makeDeviceState(seq: 10, squelch: 2)
        let (controller, sent) = makeReadyController(seed: seed)
        controller.updateDeviceState(makeDeviceState(seq: 25, squelch: 9))

        #expect(sent.frames.count == 1)
        #expect(controller.isAppliedStateInSync)
        #expect(controller.desiredState.sequence == 25)
        #expect(controller.desiredState.squelch == 9)

        controller.setSquelch(2)
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].sequence == 26)
        #expect(sent.frames[1].squelch == 2)
    }

    @Test func appliedStateSyncTracksFirmwareEcho() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        #expect(!controller.isAppliedStateInSync)

        controller.updateDeviceState(echo(sent.frames.last!))
        #expect(controller.isAppliedStateInSync)
    }

    @Test func mismatchAndLastErrorBreakSync() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        let applied = sent.frames.last!

        // Firmware error → out of sync even if fields match.
        controller.updateDeviceState(echo(applied, lastError: 3))
        #expect(!controller.isAppliedStateInSync)

        // Stale sequence → out of sync.
        var stale = applied
        stale.sequence &-= 1
        controller.updateDeviceState(echo(stale))
        #expect(!controller.isAppliedStateInSync)
    }

    @Test func retriesCappedAtThree() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        let countAfterSend = sent.frames.count
        let lastSent = sent.frames.last!

        // Firmware keeps reporting a stale sequence → retry per report, max 3.
        var stale = lastSent
        stale.sequence &-= 1
        for _ in 0..<6 {
            controller.updateDeviceState(echo(stale))
        }
        #expect(sent.frames.count == countAfterSend + RadioModuleController.maxDesiredStateRetries)
        #expect(sent.frames.suffix(RadioModuleController.maxDesiredStateRetries).allSatisfy { $0 == lastSent })

        // Once firmware catches up, sync restores and retries stop.
        controller.updateDeviceState(echo(lastSent))
        #expect(controller.isAppliedStateInSync)
        #expect(sent.frames.count == countAfterSend + RadioModuleController.maxDesiredStateRetries)
    }

    @Test func noSendsBeforeTransportReady() {
        let controller = RadioModuleController()
        let sent = SentFrames()
        controller.attachTransport { sent.frames.append($0) }
        controller.seedFromDeviceState(makeDeviceState())
        controller.setSquelch(8)
        #expect(sent.frames.isEmpty)
        controller.markTransportReady()
        #expect(sent.frames.count == 1)
        #expect(sent.frames[0].squelch == 8)
    }

    // MARK: TX_ALLOWED band gate

    @Test func txAllowedFollowsTxFrequency() {
        let (controller, sent) = makeReadyController(rfModuleType: 0)
        // Seeded in band: the post-HELLO flush grants TX.
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(controller.isTxAllowed)

        controller.setTxFrequency(156.8)  // marine ch 16
        #expect(sent.frames.count == 2)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(!controller.isTxAllowed)

        controller.setTxFrequency(147.0)
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(controller.isTxAllowed)
    }

    @Test func repeaterOffsetOutOfBandWithholdsTxInSameFrame() {
        let (controller, sent) = makeReadyController(rfModuleType: 0)
        controller.beginUpdate()
        controller.setRxFrequency(147.99)
        controller.setTxFrequency(147.99 + 0.6)
        controller.endUpdate()
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].freqRx == 147.99)
        #expect(!hasFlag(sent.frames[1], HOST_STATE_TX_ALLOWED))
    }

    @Test func bandwidthChangeRederivesTxAllowed() {
        // 147.990 clears the 148.000 edge by 10 kHz: inside a 12.5 kHz
        // channel's half-width, not a 25 kHz one's.
        let seed = makeDeviceState(bw: DRA818_25K, freqTx: 147.99, freqRx: 147.99)
        let (controller, sent) = makeReadyController(seed: seed, rfModuleType: 0)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))

        controller.setBandwidth(DRA818_12K5)
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))

        controller.setBandwidth(DRA818_25K)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
    }

    @Test func persistedTxAllowedClearedWhenSeedIsOutOfBand() {
        // Firmware restores TX_ALLOWED from NVS at boot.
        let seed = makeDeviceState(
            flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_TX_ALLOWED,
            freqTx: 162.55, freqRx: 162.55)
        let (_, sent) = makeReadyController(seed: seed, rfModuleType: 0)
        #expect(sent.frames.count == 1)
        #expect(!hasFlag(sent.frames[0], HOST_STATE_TX_ALLOWED))
    }

    @Test func noTxAllowedWithoutHello() {
        let seed = makeDeviceState(flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_TX_ALLOWED)
        let (controller, sent) = makeReadyController(seed: seed)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(!controller.canTransmit(onFrequency: 146.52))
    }

    @Test func pttWithheldOutOfBand() {
        let seed = makeDeviceState(freqTx: 151.82, freqRx: 151.82)  // MURS
        let (controller, sent) = makeReadyController(seed: seed, rfModuleType: 0)
        let count = sent.frames.count
        controller.pttDown()
        #expect(sent.frames.count == count)  // nothing to send
        #expect(!hasFlag(controller.desiredState, HOST_STATE_PTT_REQUESTED))

        controller.beginUpdate()
        controller.setRxFrequency(146.52)
        controller.setTxFrequency(146.52)
        controller.pttDown()
        controller.endUpdate()
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(hasFlag(sent.frames.last, HOST_STATE_PTT_REQUESTED))
    }

    @Test func outOfBandTuneDropsHeldPtt() {
        let (controller, sent) = makeReadyController(rfModuleType: 0)
        controller.pttDown()
        #expect(hasFlag(sent.frames.last, HOST_STATE_PTT_REQUESTED))

        controller.setTxFrequency(150.0)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(!hasFlag(sent.frames.last, HOST_STATE_PTT_REQUESTED))

        // Back in band, the dropped PTT stays dropped.
        controller.setTxFrequency(146.52)
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(!hasFlag(sent.frames.last, HOST_STATE_PTT_REQUESTED))
    }

    @Test func uhfModuleUsesSeventyCentimeterLimits() {
        let seed = makeDeviceState(freqTx: 446.0, freqRx: 446.0)
        let (controller, sent) = makeReadyController(seed: seed, rfModuleType: 1)
        #expect(hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
        #expect(controller.canTransmit(onFrequency: 432.1))
        #expect(!controller.canTransmit(onFrequency: 146.52))

        controller.setTxFrequency(462.5625)  // FRS/GMRS
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
    }

    @Test func adoptedDeviceStateRederivesTxAllowed() {
        let (controller, sent) = makeReadyController(rfModuleType: 0)
        let count = sent.frames.count
        // Firmware jumps ahead with an out-of-band tune still flagged TX_ALLOWED.
        controller.updateDeviceState(makeDeviceState(
            seq: 50,
            flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_TX_ALLOWED,
            freqTx: 155.0, freqRx: 155.0))
        #expect(sent.frames.count == count + 1)
        #expect(sent.frames.last?.freqTx == 155.0)
        #expect(!hasFlag(sent.frames.last, HOST_STATE_TX_ALLOWED))
    }
}

struct FlowControlGateTests {

    private func makeGate(window: Int) -> (FlowControlGate, SentData) {
        let gate = FlowControlGate()
        let sent = SentData()
        gate.onSend = { sent.frames.append($0) }
        gate.setWindow(window)
        return (gate, sent)
    }

    final class SentData {
        var frames: [Data] = []
    }

    @Test func decrementsWindowByWireLength() {
        let (gate, sent) = makeGate(window: 100)
        gate.submit(Data(count: 30))
        #expect(sent.frames.count == 1)
        #expect(gate.window == 70)
    }

    @Test func defersFramesWhenWindowTooSmall() {
        let (gate, sent) = makeGate(window: 10)
        gate.submit(Data(count: 30))
        #expect(sent.frames.isEmpty)
        #expect(gate.pending.count == 1)
    }

    @Test func windowUpdateDrainsQueueInOrder() {
        let (gate, sent) = makeGate(window: 0)
        gate.submit(Data([1]))
        gate.submit(Data([2, 2]))
        gate.submit(Data([3, 3, 3]))
        #expect(sent.frames.isEmpty)

        gate.enlargeWindow(by: 3)  // fits first two only
        #expect(sent.frames == [Data([1]), Data([2, 2])])
        #expect(gate.window == 0)

        gate.enlargeWindow(by: 10)
        #expect(sent.frames.count == 3)
        #expect(sent.frames[2] == Data([3, 3, 3]))
        #expect(gate.window == 7)
    }

    @Test func preservesOrderEvenWhenLaterFrameFits() {
        let (gate, sent) = makeGate(window: 5)
        gate.submit(Data(count: 10))  // blocked
        gate.submit(Data(count: 2))   // would fit, but must wait its turn
        #expect(sent.frames.isEmpty)
        gate.enlargeWindow(by: 10)
        #expect(sent.frames.count == 2)
        #expect(sent.frames[0].count == 10)
    }

    @Test func resetRestoresDefaultWindowAndDropsQueue() {
        let (gate, sent) = makeGate(window: 0)
        gate.submit(Data(count: 4))
        gate.reset()
        #expect(gate.pending.isEmpty)
        #expect(gate.window == FlowControlGate.defaultWindow)
        #expect(sent.frames.isEmpty)
    }
}
