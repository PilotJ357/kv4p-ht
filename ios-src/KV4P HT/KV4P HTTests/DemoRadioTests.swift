import Testing
import Foundation
import CoreLocation
@testable import KV4P_HT

// Collects DemoRadio callbacks; touched only on the demo's queue.
private final class DemoSink: @unchecked Sendable {
    var states: [DeviceStateFrame] = []
    var frames: [AX25Frame] = []
}

private func makeDemo() -> (DemoRadio, DispatchQueue, DemoSink) {
    let queue = DispatchQueue(label: "demo-radio-tests")
    let demo = DemoRadio(queue: queue, center: DemoRadio.defaultCenter)
    let sink = DemoSink()
    demo.onDeviceState = { sink.states.append($0) }
    demo.onAx25Frame = { data in
        if let f = AX25Frame(decoding: data) { sink.frames.append(f) }
    }
    return (demo, queue, sink)
}

// Polls `condition` on the demo's queue until true or the timeout passes.
private func waitOn(_ queue: DispatchQueue, timeout: Double = 3,
                    _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if queue.sync(execute: condition) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

struct DemoRadioTests {

    @Test func controllerSyncsAgainstDemoEcho() {
        let (demo, queue, _) = makeDemo()
        let radio = RadioModuleController()
        demo.onDeviceState = { radio.updateDeviceState($0) }
        // Demo is queue-confined; drive the controller from that queue too.
        queue.sync {
            demo.start()
            let hello = demo.hello
            radio.attachTransport { state in demo.apply(state) }
            radio.seedFirmwareInfo(hello)
            radio.seedFromDeviceState(hello.deviceState)
            radio.beginUpdate()
            radio.markTransportReady()
            radio.setTxAllowed(true)
            radio.openAudio()
            radio.endUpdate()
            #expect(radio.isAppliedStateInSync)

            // Tune + key up: applied state follows and reports TX.
            radio.beginUpdate()
            radio.setRxFrequency(147.0)
            radio.setTxFrequency(147.6)
            radio.pttDown()
            radio.endUpdate()
            #expect(radio.isAppliedStateInSync)
            #expect(radio.deviceState?.freqRx == 147.0)
            #expect(radio.deviceState?.freqTx == 147.6)
            #expect(radio.deviceState?.mode == 0)
            #expect(radio.deviceState.map { $0.flags & DEVICE_STATE_TX_ACTIVE != 0 } == true)

            radio.pttUp()
            #expect(radio.deviceState?.mode == 1)
            demo.stop()
        }
    }

    @Test func noTransmitWithoutTxAllowed() {
        let (demo, queue, sink) = makeDemo()
        queue.sync {
            demo.start()
            var state = HostDesiredState(
                sequence: 1, memoryId: -1,
                flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_PTT_REQUESTED,
                bw: DRA818_25K, freqTx: 146.52, freqRx: 146.52,
                ctcssTx: 0, squelch: 3, ctcssRx: 0)
            demo.apply(state)
            #expect(sink.states.last?.mode == 1)
            state.flags |= HOST_STATE_TX_ALLOWED
            demo.apply(state)
            #expect(sink.states.last?.mode == 0)
            demo.stop()
        }
    }

    @Test func outgoingMessageGetsAckAndReply() async throws {
        let (demo, queue, sink) = makeDemo()
        demo.replyDelays = (0.05, 0.1)
        let me = AX25Callsign(base: "N0CALL", ssid: 7)
        let out = AX25Frame(source: me, payload: Data(
            messagePayload(to: "DEMO2-7", text: "hello", msgNum: "42").utf8))
        queue.sync {
            demo.start()
            demo.receiveAx25(out.encodedWithoutFCS())
        }
        let gotBoth = await waitOn(queue) {
            sink.frames.filter { $0.source.display == "DEMO2-7" }.count >= 2
        }
        #expect(gotBoth)
        let replies = queue.sync { sink.frames.filter { $0.source.display == "DEMO2-7" } }
        guard replies.count >= 2 else { return }

        guard case let .message(to, _, num, isAck, _) = parseAPRSPayload(replies[0].payload) else {
            Issue.record("ack is not a message"); return
        }
        #expect(to == "N0CALL-7")
        #expect(isAck)
        #expect(num == "42")

        guard case let .message(to2, body, num2, isAck2, _) = parseAPRSPayload(replies[1].payload) else {
            Issue.record("reply is not a message"); return
        }
        #expect(to2 == "N0CALL-7")
        #expect(!isAck2)
        #expect(!body.isEmpty)
        #expect(num2 != nil)
        queue.sync { demo.stop() }
    }

    @Test func noRepliesAfterStop() async {
        let (demo, queue, sink) = makeDemo()
        demo.replyDelays = (0.05, 0.1)
        let out = AX25Frame(source: AX25Callsign(base: "N0CALL", ssid: 0), payload: Data(
            messagePayload(to: "DEMO3", text: "hi", msgNum: "1").utf8))
        queue.sync {
            demo.start()
            demo.receiveAx25(out.encodedWithoutFCS())
            demo.stop()
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(queue.sync { sink.frames.isEmpty })
    }

    @Test func cannedPacketsParse() async {
        let (demo, queue, sink) = makeDemo()
        queue.sync { demo.start() }
        // Bulletin at ~2 s, first position 10 s later.
        let got = await waitOn(queue, timeout: 15) { sink.frames.count >= 2 }
        queue.sync { demo.stop() }
        #expect(got)
        let frames = queue.sync { sink.frames }
        guard frames.count >= 2 else { return }
        guard case let .message(to, _, _, _, _) = parseAPRSPayload(frames[0].payload) else {
            Issue.record("first packet is not a bulletin"); return
        }
        #expect(to == "BLN1")
        guard case let .position(lat, lon, _, code, _, _) = parseAPRSPayload(frames[1].payload) else {
            Issue.record("second packet is not a position"); return
        }
        #expect(abs(lat - DemoRadio.defaultCenter.latitude) < 0.1)
        #expect(abs(lon - DemoRadio.defaultCenter.longitude) < 0.1)
        #expect(code == ">")
    }
}
