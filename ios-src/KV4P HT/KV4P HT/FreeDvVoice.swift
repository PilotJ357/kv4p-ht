import Foundation
import Codec2Swift

// FreeDV 2400B voice framing. The radio runs the 2400B modem; the app only
// exchanges Codec2 1300 frames with it (KV4P vendor command 0x0E, one 7-byte
// frame per command, one frame per 40 ms). Matches Android's
// RadioAudioService.sendFreeDvAudio / decodeAndPlayFreeDvFrame.

/// 16 kHz mic samples → 2:1 pair-average → 320-sample 8 kHz frames → 7-byte
/// Codec2 frames. Not thread-safe; owned by the mic tap thread.
nonisolated final class Codec2TxFramer {
    private let codec = Codec2()
    private var pcm = [Int16](repeating: 0, count: Codec2.pcmSamples)
    private var frame = [UInt8](repeating: 0, count: Codec2.frameBytes)
    private var count = 0
    private var pending: Int16?

    /// Feeds one 16 kHz sample; calls `emit` with a 7-byte frame every 640 samples.
    func push(_ sample: Int16, emit: (Data) -> Void) {
        guard let first = pending else { pending = sample; return }
        pending = nil
        pcm[count] = Int16((Int32(first) + Int32(sample)) / 2)
        count += 1
        guard count == Codec2.pcmSamples else { return }
        count = 0
        pcm.withUnsafeBufferPointer { p in
            frame.withUnsafeMutableBufferPointer { f in
                codec.encode(p.baseAddress!, into: f.baseAddress!)
            }
        }
        emit(Data(frame))
    }

    /// Drops any partial frame (PTT start/stop). Codec state carries over.
    func reset() {
        count = 0
        pending = nil
    }
}

/// 7-byte Codec2 frame → 320 samples at 8 kHz → 640 Float samples at 16 kHz
/// (sample duplication, as Android does). Not thread-safe; owned by the BLE queue.
nonisolated final class Codec2RxDecoder {
    static let outputSamples = Codec2.pcmSamples * 2

    private let codec = Codec2()
    private var pcm = [Int16](repeating: 0, count: Codec2.pcmSamples)

    /// Decodes into `out` (at least `outputSamples` long). Returns false for a
    /// payload that isn't exactly one frame.
    func decode(_ data: Data, into out: UnsafeMutablePointer<Float>) -> Bool {
        guard data.count == Codec2.frameBytes else { return false }
        pcm.withUnsafeMutableBufferPointer { p in
            data.withUnsafeBytes { b in
                codec.decode(b.bindMemory(to: UInt8.self).baseAddress!, into: p.baseAddress!)
            }
        }
        for i in 0..<Codec2.pcmSamples {
            let s = Float(pcm[i]) / 32768.0
            out[i * 2] = s
            out[i * 2 + 1] = s
        }
        return true
    }
}
