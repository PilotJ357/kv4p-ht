import Foundation

// Voice TX mic gain boost (Android MicGainBoost parity). Applied to mic
// samples before ADPCM encode, so the firmware's TX audio level (the S-meter
// in TX) reads post-gain. APRS/AFSK is modulated in firmware and never sees it.
nonisolated enum MicGainBoost: String, CaseIterable {
    case none = "None"
    case low  = "Low"
    case med  = "Med"
    case high = "High"

    var gain: Float {
        switch self {
        case .none: return 1.0
        case .low:  return 1.5
        case .med:  return 2.0
        case .high: return 2.5
        }
    }

    // Case-insensitive label match; anything unknown falls back to None.
    static func parse(_ str: String) -> MicGainBoost {
        allCases.first { $0.rawValue.caseInsensitiveCompare(str) == .orderedSame } ?? .none
    }

    // Float mic sample → gained Int16 PCM, saturating at full scale instead
    // of wrapping (Android clamps to Short.MIN/MAX the same way).
    static func pcm16(_ sample: Float, gain: Float) -> Int16 {
        let s = max(-1.0, min(1.0, sample * gain))
        return Int16(s * 32767.0)
    }
}
