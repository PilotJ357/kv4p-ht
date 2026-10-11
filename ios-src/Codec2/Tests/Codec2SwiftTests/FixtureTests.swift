import CryptoKit
import Foundation
import Testing
@testable import Codec2Swift

// Real FreeDV 2400B speech (VE9QRP recording). See Fixtures/README.md for
// provenance and how the upstream-generated goldens were made.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil,
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func frames(_ data: Data) -> [[UInt8]] {
    stride(from: 0, to: data.count, by: Codec2.frameBytes).map {
        Array(data[$0..<($0 + Codec2.frameBytes)])
    }
}

private func samples(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count, by: 2).map {
        Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
    }
}

private func frameRms(_ pcm: [Int16]) -> [Double] {
    stride(from: 0, to: pcm.count, by: Codec2.pcmSamples).map { start in
        let f = pcm[start..<(start + Codec2.pcmSamples)]
        return sqrt(f.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(f.count))
    }
}

private func correlation(_ a: [Double], _ b: [Double]) -> Double {
    let n = Double(a.count)
    let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var ab = 0.0, aa = 0.0, bb = 0.0
    for (x, y) in zip(a, b) {
        ab += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb)
    }
    return ab / sqrt(aa * bb)
}

private func decodeAll(_ input: [[UInt8]]) -> [Int16] {
    let c = Codec2()
    return input.flatMap { c.decode($0) }
}

struct FixtureTests {

    @Test func voiceFramesFixtureIsIntact() throws {
        let data = try fixture("ve9qrp_2400b_voice_frames.bin")
        #expect(data.count == 2810 * Codec2.frameBytes)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                == "f2d71011d274bc6d259d16f3db53c596b03ce51c43fd3dc9562d034e6c3c3884")
        // 52 bits per frame: the low nibble of the last byte is padding.
        #expect(frames(data).allSatisfy { $0[6] & 0x0F == 0 })
    }

    /// Decoded loudness follows upstream `c2dec 1300` frame by frame. Not a
    /// PCM hash: Codec2 synthesises unvoiced phases from a process-global RNG
    /// (`codec2_rand` in sine.c), so the waveform depends on prior decodes.
    @Test func decodesRealSpeechLikeUpstream() throws {
        let ours = frameRms(decodeAll(frames(try fixture("ve9qrp_2400b_voice_frames.bin"))))
        let golden = samples(try fixture("ve9qrp_c2dec_rms.bin")).map { Double(UInt16(bitPattern: $0)) }
        #expect(ours.count == golden.count)
        let r = correlation(ours, golden)
        let level = ours.reduce(0, +) / golden.reduce(0, +)
        #expect(r > 0.99, "envelope correlation \(r)")
        #expect(abs(level - 1) < 0.05, "level ratio \(level)")
    }

    /// The encoder is deterministic, so real speech must encode bit-exactly
    /// like upstream `c2enc 1300`.
    @Test func encoderMatchesUpstreamOnRealSpeech() throws {
        let pcm = samples(try fixture("ve9qrp_c2dec_first3s.raw"))
        let golden = frames(try fixture("ve9qrp_c2dec_first3s_c2enc.bin"))
        let c = Codec2()
        let ours = stride(from: 0, to: pcm.count, by: Codec2.pcmSamples).map {
            c.encode(Array(pcm[$0..<($0 + Codec2.pcmSamples)]))
        }
        #expect(ours.count == golden.count)
        let mismatches = zip(ours, golden).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(mismatches.isEmpty, "frames differing from c2enc: \(mismatches)")
    }

    /// Encoder output looped back into the decoder: decode the recording,
    /// re-encode it, decode again. Tandem coding isn't lossless, but speech
    /// must survive.
    @Test func loopbackPreservesRealSpeech() throws {
        let original = frames(try fixture("ve9qrp_2400b_voice_frames.bin"))
        let firstPcm = decodeAll(original)
        let enc = Codec2()
        let tandem = stride(from: 0, to: firstPcm.count, by: Codec2.pcmSamples).map {
            enc.encode(Array(firstPcm[$0..<($0 + Codec2.pcmSamples)]))
        }
        let secondPcm = decodeAll(tandem)

        // Upstream c2dec | c2enc flips 22% of bits; random bits would flip 50%.
        let flipped = zip(original, tandem).reduce(0) { sum, pair in
            sum + zip(pair.0, pair.1).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        }
        let ber = Double(flipped) / Double(original.count * 52)
        #expect(ber < 0.26, "tandem bit error rate \(ber)")

        // Upstream c2dec | c2enc | c2dec gives 0.92.
        let r = correlation(frameRms(firstPcm), frameRms(secondPcm))
        #expect(r > 0.88, "loopback envelope correlation \(r)")
    }
}
