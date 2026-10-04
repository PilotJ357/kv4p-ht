import AVFoundation

// Microphone permission as far as voice PTT cares.
nonisolated enum MicPermission: Equatable {
    case undetermined, denied, granted

    init(_ p: AVAudioApplication.recordPermission) {
        switch p {
        case .granted: self = .granted
        case .denied:  self = .denied
        default:       self = .undetermined
        }
    }
}

// Decides what a voice PTT press does. Checked before PTT_REQUESTED goes
// out: BLEManager keys the radio first and only then starts mic capture, so
// without this a denied (or still-prompting) mic transmits a dead carrier.
// APRS/AX.25 TX doesn't use the mic and doesn't go through here.
nonisolated enum PTTGate {
    enum Decision: Equatable {
        case key
        // Ask for the mic; this press does not key.
        case requestMic
        // TX frequency outside the amateur band (RX ONLY).
        case outOfBand
        // First transmission: confirm an amateur license; this press does not key.
        case needsLicenseAck
        // Mic denied; PTT stays inert until allowed in Settings.
        case micDenied
    }

    // micRequired is false for the Demo Radio, which never captures the mic
    // or transmits, so it skips the license check too.
    static func decide(outOfBand: Bool, licenseAcked: Bool, mic: MicPermission, micRequired: Bool) -> Decision {
        if outOfBand { return .outOfBand }
        guard micRequired else { return .key }
        guard licenseAcked else { return .needsLicenseAck }
        switch mic {
        case .granted:      return .key
        case .undetermined: return .requestMic
        case .denied:       return .micDenied
        }
    }
}
