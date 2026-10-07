import Testing
import Foundation
@testable import KV4P_HT

private func write(_ rb: PCMRingBuffer, _ value: Float, count: Int) {
    let samples = [Float](repeating: value, count: count)
    samples.withUnsafeBufferPointer { _ = rb.write($0.baseAddress!, frameCount: count) }
}

private func read(_ rb: PCMRingBuffer, count: Int) -> [Float] {
    var out = [Float](repeating: -1, count: count)
    out.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, frameCount: count) }
    return out
}

// The squelch flag arrives with the audio it belongs to, but that audio plays
// a jitter-buffer depth later. Mute changes must land on the stream position,
// not the moment they're requested.
struct RxMuteAlignmentTests {

    @Test func muteWaitsForBufferedAudioToPlay() {
        let rb = PCMRingBuffer(capacity: 100)
        write(rb, 0.5, count: 10)  // transmission tail, still buffered
        rb.setMuted(true)          // squelch closes now
        write(rb, 0.9, count: 10)  // after close

        #expect(read(rb, count: 10) == [Float](repeating: 0.5, count: 10))
        #expect(read(rb, count: 10) == [Float](repeating: 0, count: 10))
    }

    @Test func muteSplitsInsideOneRenderBlock() {
        let rb = PCMRingBuffer(capacity: 100)
        write(rb, 0.5, count: 4)
        rb.setMuted(true)
        write(rb, 0.9, count: 4)
        rb.setMuted(false)
        write(rb, 0.3, count: 4)

        let out = read(rb, count: 12)
        #expect(out == [0.5, 0.5, 0.5, 0.5, 0, 0, 0, 0, 0.3, 0.3, 0.3, 0.3])
    }

    // Reopen must not replay audio buffered while closed (e.g. the previous
    // transmission's squelch tail).
    @Test func unmuteDoesNotRevealAudioBufferedWhileMuted() {
        let rb = PCMRingBuffer(capacity: 100)
        rb.setMuted(true)
        write(rb, 0.7, count: 10)  // closed-squelch audio
        rb.setMuted(false)         // squelch opens
        write(rb, 0.2, count: 10)  // new transmission

        #expect(read(rb, count: 10) == [Float](repeating: 0, count: 10))
        #expect(read(rb, count: 10) == [Float](repeating: 0.2, count: 10))
    }

    @Test func changeAtBlockBoundaryAppliesToNextBlock() {
        let rb = PCMRingBuffer(capacity: 100)
        write(rb, 0.5, count: 8)
        rb.setMuted(true)
        #expect(read(rb, count: 8) == [Float](repeating: 0.5, count: 8))

        write(rb, 0.9, count: 8)
        #expect(read(rb, count: 8) == [Float](repeating: 0, count: 8))
    }

    @Test func emptyBufferAppliesImmediately() {
        let rb = PCMRingBuffer(capacity: 100)
        rb.setMuted(true)
        write(rb, 0.9, count: 5)
        #expect(read(rb, count: 5) == [Float](repeating: 0, count: 5))
    }

    @Test func clearAppliesPendingChanges() {
        let rb = PCMRingBuffer(capacity: 100)
        write(rb, 0.5, count: 10)
        rb.setMuted(true)
        rb.clear()  // jitter-buffer re-arm skips to the write head
        write(rb, 0.9, count: 5)
        #expect(read(rb, count: 5) == [Float](repeating: 0, count: 5))
    }

    @Test func positionsSurviveClearAndWrap() {
        let rb = PCMRingBuffer(capacity: 16)
        for _ in 0..<5 {
            write(rb, 0.1, count: 12)
            _ = read(rb, count: 12)
        }
        rb.clear()
        write(rb, 0.5, count: 6)
        rb.setMuted(true)
        write(rb, 0.9, count: 6)
        #expect(read(rb, count: 12) == [Float](repeating: 0.5, count: 6) + [Float](repeating: 0, count: 6))
    }

    @Test func repeatedRequestIsIgnored() {
        let rb = PCMRingBuffer(capacity: 100)
        write(rb, 0.5, count: 4)
        rb.setMuted(false)  // already unmuted
        write(rb, 0.5, count: 4)
        #expect(read(rb, count: 8) == [Float](repeating: 0.5, count: 8))
    }
}
