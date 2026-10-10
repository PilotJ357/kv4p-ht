import CCodec2

/// Thin wrapper around a Codec2 1300 encoder/decoder state.
///
/// One frame = 320 samples of 8 kHz mono Int16 ↔ 7 bytes (52 bits, 40 ms).
/// An instance is NOT thread-safe; use separate instances for encode and
/// decode when they run on different threads.
public final class Codec2 {
    public static let pcmSamples = 320
    public static let frameBytes = 7
    public static let sampleRate = 8000

    private let state: OpaquePointer

    public init() {
        guard let s = codec2_create(CODEC2_MODE_1300) else {
            fatalError("codec2_create(CODEC2_MODE_1300) failed")
        }
        precondition(codec2_samples_per_frame(s) == Int32(Self.pcmSamples))
        precondition(codec2_bytes_per_frame(s) == Int32(Self.frameBytes))
        state = s
    }

    deinit {
        codec2_destroy(state)
    }

    /// Encodes `pcmSamples` Int16 samples into `frameBytes` bytes.
    public func encode(_ pcm: UnsafePointer<Int16>, into frame: UnsafeMutablePointer<UInt8>) {
        // codec2_encode's speech_in isn't const-qualified, but it is only
        // read (copied into the analysis window in analyse_one_frame).
        codec2_encode(state, frame, UnsafeMutablePointer(mutating: pcm))
    }

    /// Decodes `frameBytes` bytes into `pcmSamples` Int16 samples.
    public func decode(_ frame: UnsafePointer<UInt8>, into pcm: UnsafeMutablePointer<Int16>) {
        codec2_decode(state, pcm, frame)
    }

    /// Convenience: encode an array of exactly `pcmSamples` samples.
    public func encode(_ pcm: [Int16]) -> [UInt8] {
        precondition(pcm.count == Self.pcmSamples)
        var out = [UInt8](repeating: 0, count: Self.frameBytes)
        pcm.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                encode(p.baseAddress!, into: o.baseAddress!)
            }
        }
        return out
    }

    /// Convenience: decode exactly `frameBytes` bytes.
    public func decode(_ frame: [UInt8]) -> [Int16] {
        precondition(frame.count == Self.frameBytes)
        var out = [Int16](repeating: 0, count: Self.pcmSamples)
        frame.withUnsafeBufferPointer { f in
            out.withUnsafeMutableBufferPointer { o in
                decode(f.baseAddress!, into: o.baseAddress!)
            }
        }
        return out
    }
}
