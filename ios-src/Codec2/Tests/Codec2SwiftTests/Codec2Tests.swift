import Foundation
import Testing
@testable import Codec2Swift

/// Harmonic-rich "voiced" test signal: 120 Hz fundamental + 23 harmonics.
/// Codec2 models speech as harmonics of a pitch, so a pure sine round-trips
/// poorly (upstream c2enc/c2dec too); this signal is speech-like enough.
private func voiced(frames: Int) -> [Int16] {
    (0..<(frames * Codec2.pcmSamples)).map { i in
        var s = 0.0
        for k in 1..<25 {
            s += 3000.0 / Double(k) * sin(2 * .pi * 120 * Double(k) * Double(i) / 8000)
        }
        return Int16(s)
    }
}

private func rms(_ s: ArraySlice<Int16>) -> Double {
    sqrt(s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(s.count, 1)))
}

private func frame(_ pcm: [Int16], _ f: Int) -> [Int16] {
    Array(pcm[(f * Codec2.pcmSamples)..<((f + 1) * Codec2.pcmSamples)])
}

@Test func frameSizesMatchMode1300() {
    let c = Codec2()
    let encoded = c.encode([Int16](repeating: 0, count: Codec2.pcmSamples))
    #expect(encoded.count == 7)
    #expect(c.decode(encoded).count == 320)
}

/// Bytes produced by upstream codec2 1.2.0 `c2enc 1300` for `voiced(frames: 1)`.
/// Guards against a broken vendoring (missing codebook, wrong mode flags).
@Test func matchesUpstreamEncoder() {
    let c = Codec2()
    #expect(c.encode(frame(voiced(frames: 1), 0)) == [0xf2, 0xfc, 0x03, 0x76, 0x75, 0x40, 0xc0])
}

@Test func roundTripPreservesEnergy() {
    let enc = Codec2(), dec = Codec2()
    let input = voiced(frames: 25)
    var output: [Int16] = []
    for f in 0..<25 { output += dec.decode(enc.encode(frame(input, f))) }
    // Skip the first frames while the codec's filters settle.
    let inRms = rms(input[1600...]), outRms = rms(output[1600...])
    #expect(outRms > inRms * 0.5)
    #expect(outRms < inRms * 2)
}

@Test func encodingIsDeterministic() {
    let input = voiced(frames: 5)
    func run() -> [UInt8] {
        let c = Codec2()
        return (0..<5).flatMap { c.encode(frame(input, $0)) }
    }
    #expect(run() == run())
}
