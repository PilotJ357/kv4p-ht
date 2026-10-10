import Testing
import Foundation
@testable import KV4P_HT

private final class SentFrames {
    var frames: [HostDesiredState] = []
}

private func readyController(features: UInt8) -> (RadioModuleController, SentFrames) {
    let ds = DeviceStateFrame(
        appliedSequence: 7, memoryId: -1,
        flags: HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED,
        bw: DRA818_25K, freqTx: 146.52, freqRx: 146.52,
        ctcssTx: 0, squelch: 2, ctcssRx: 0,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: 0, rssi: 100)
    let controller = RadioModuleController()
    let sent = SentFrames()
    controller.attachTransport { sent.frames.append($0) }
    controller.seedFirmwareInfo(HelloFrame(
        firmwareVersion: 17, radioModuleFound: true, windowSize: 1024, rfModuleType: 0,
        minFreq: 134, maxFreq: 174, features: features, deviceState: ds))
    controller.seedFromDeviceState(ds)
    controller.markTransportReady()
    return (controller, sent)
}

struct FreeDvTests {

    // MARK: Controller flag

    @Test func setFreeDvSetsBit13WhenSupported() {
        let (controller, sent) = readyController(features: 0x08)
        #expect(controller.hasFreeDv2400b)
        controller.setFreeDv2400b(true)
        #expect((sent.frames.last?.flags ?? 0) & HOST_STATE_FREEDV_2400B != 0)
        controller.setFreeDv2400b(false)
        #expect((sent.frames.last?.flags ?? 0) & HOST_STATE_FREEDV_2400B == 0)
    }

    @Test func setFreeDvIgnoredWithoutFeatureBit() {
        let (controller, sent) = readyController(features: 0x01)
        #expect(!controller.hasFreeDv2400b)
        let before = sent.frames.count
        controller.setFreeDv2400b(true)
        #expect(sent.frames.count == before)
        #expect(controller.desiredState.flags & HOST_STATE_FREEDV_2400B == 0)
    }

    // MARK: Wire framing

    @Test func digitalFrameRoundTripsThroughKiss() {
        // 0xC0/0xDB force KISS escaping.
        let payload = Data([0xC0, 0x01, 0xDB, 0x02, 0x03, 0xC0, 0x04])
        let frames = KissParser().feed(buildKv4pVendorFrame(command: 0x0E, payload: payload))
        #expect(frames.count == 1)
        guard let (cmd, body) = frames.first else { return }
        #expect(cmd == 0x06)
        #expect(body.prefix(4) == Data(KV4P_VENDOR_PREFIX))
        #expect(body[body.startIndex + 5] == 0x0E)
        #expect(Data(body.dropFirst(6)) == payload)
    }

    // MARK: TX framer

    @Test func txFramerEmitsOneFramePer640Samples() {
        let framer = Codec2TxFramer()
        var out: [Data] = []
        for i in 0..<(640 * 3 + 639) {
            framer.push(Int16(truncatingIfNeeded: (i % 80) * 200 - 8000)) { out.append($0) }
        }
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.count == 7 })
        // One more sample completes frame 4.
        framer.push(0) { out.append($0) }
        #expect(out.count == 4)
    }

    @Test func txFramerResetDropsPartialFrame() {
        let framer = Codec2TxFramer()
        var out: [Data] = []
        for _ in 0..<601 { framer.push(1000) { out.append($0) } }  // odd: leaves a pending sample
        framer.reset()
        for _ in 0..<639 { framer.push(1000) { out.append($0) } }
        #expect(out.isEmpty)
        framer.push(1000) { out.append($0) }
        #expect(out.count == 1)
    }

    // MARK: RX decoder

    @Test func rxDecoderUpsamplesByDuplication() {
        let decoder = Codec2RxDecoder()
        var buf = [Float](repeating: .nan, count: Codec2RxDecoder.outputSamples)
        let ok = buf.withUnsafeMutableBufferPointer {
            decoder.decode(Data([0xf2, 0xfc, 0x03, 0x76, 0x75, 0x40, 0xc0]), into: $0.baseAddress!)
        }
        #expect(ok)
        #expect(buf.count == 640)
        #expect(buf.allSatisfy { !$0.isNaN && abs($0) <= 1 })
        #expect(stride(from: 0, to: 640, by: 2).allSatisfy { buf[$0] == buf[$0 + 1] })
    }

    @Test func rxDecoderRejectsWrongSize() {
        let decoder = Codec2RxDecoder()
        var buf = [Float](repeating: 0, count: Codec2RxDecoder.outputSamples)
        for size in [0, 6, 8, 14] {
            let ok = buf.withUnsafeMutableBufferPointer {
                decoder.decode(Data(count: size), into: $0.baseAddress!)
            }
            #expect(!ok)
        }
    }
}
