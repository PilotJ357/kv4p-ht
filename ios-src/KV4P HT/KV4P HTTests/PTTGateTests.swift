import AVFoundation
import Testing
@testable import KV4P_HT

struct PTTGateTests {

    @Test func grantedKeys() {
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: true, mic: .granted, micRequired: true) == .key)
    }

    @Test func undeterminedRequestsInsteadOfKeying() {
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: true, mic: .undetermined, micRequired: true) == .requestMic)
    }

    @Test func deniedNeverKeys() {
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: true, mic: .denied, micRequired: true) == .micDenied)
    }

    @Test(arguments: [MicPermission.undetermined, .denied, .granted])
    func outOfBandWins(mic: MicPermission) {
        for acked in [false, true] {
            #expect(PTTGate.decide(outOfBand: true, licenseAcked: acked, mic: mic, micRequired: true) == .outOfBand)
            #expect(PTTGate.decide(outOfBand: true, licenseAcked: acked, mic: mic, micRequired: false) == .outOfBand)
        }
    }

    // License confirmation comes before the mic prompt and never keys.
    @Test(arguments: [MicPermission.undetermined, .denied, .granted])
    func unacknowledgedLicenseAsksFirst(mic: MicPermission) {
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: false, mic: mic, micRequired: true) == .needsLicenseAck)
    }

    // Demo Radio never captures the mic or transmits, so neither gates it.
    @Test(arguments: [MicPermission.undetermined, .denied, .granted])
    func demoIgnoresMicAndLicense(mic: MicPermission) {
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: false, mic: mic, micRequired: false) == .key)
        #expect(PTTGate.decide(outOfBand: false, licenseAcked: true, mic: mic, micRequired: false) == .key)
    }

    @Test func mapsSystemPermission() {
        #expect(MicPermission(.granted) == .granted)
        #expect(MicPermission(.denied) == .denied)
        #expect(MicPermission(.undetermined) == .undetermined)
    }
}
