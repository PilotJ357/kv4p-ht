import Testing
@testable import KV4P_HT

struct MicGainBoostTests {

    @Test func gainsMatchAndroid() {
        #expect(MicGainBoost.none.gain == 1.0)
        #expect(MicGainBoost.low.gain == 1.5)
        #expect(MicGainBoost.med.gain == 2.0)
        #expect(MicGainBoost.high.gain == 2.5)
    }

    @Test func parseIsCaseInsensitiveAndDefaultsToNone() {
        #expect(MicGainBoost.parse("High") == .high)
        #expect(MicGainBoost.parse("med") == .med)
        #expect(MicGainBoost.parse("LOW") == .low)
        #expect(MicGainBoost.parse("") == .none)
        #expect(MicGainBoost.parse("bogus") == .none)
    }

    @Test func unityGainIsUnchanged() {
        #expect(MicGainBoost.pcm16(0, gain: 1.0) == 0)
        #expect(MicGainBoost.pcm16(0.5, gain: 1.0) == 16383)
        #expect(MicGainBoost.pcm16(-0.5, gain: 1.0) == -16383)
        #expect(MicGainBoost.pcm16(1.0, gain: 1.0) == 32767)
    }

    @Test func scalesBelowFullScale() {
        #expect(MicGainBoost.pcm16(0.2, gain: 2.0) == 13106)
        #expect(MicGainBoost.pcm16(-0.2, gain: 2.5) == -16383)
    }

    @Test func saturatesInsteadOfWrapping() {
        #expect(MicGainBoost.pcm16(0.5, gain: 2.5) == Int16.max)
        #expect(MicGainBoost.pcm16(-0.5, gain: 2.5) == -Int16.max)
        #expect(MicGainBoost.pcm16(0.9, gain: 1.5) == Int16.max)
        // Out-of-range input (some mics overshoot ±1.0) still clamps.
        #expect(MicGainBoost.pcm16(3.0, gain: 1.0) == Int16.max)
        #expect(MicGainBoost.pcm16(-3.0, gain: 2.0) == -Int16.max)
    }
}
