import AVFoundation
import Testing
@testable import KV4P_HT

struct PTTGateTests {

    @Test func grantedKeys() {
        #expect(PTTGate.decide(outOfBand: false, mic: .granted, micRequired: true) == .key)
    }

    @Test func undeterminedRequestsInsteadOfKeying() {
        #expect(PTTGate.decide(outOfBand: false, mic: .undetermined, micRequired: true) == .requestMic)
    }

    @Test func deniedNeverKeys() {
        #expect(PTTGate.decide(outOfBand: false, mic: .denied, micRequired: true) == .micDenied)
    }

    @Test(arguments: [MicPermission.undetermined, .denied, .granted])
    func outOfBandWins(mic: MicPermission) {
        #expect(PTTGate.decide(outOfBand: true, mic: mic, micRequired: true) == .outOfBand)
        #expect(PTTGate.decide(outOfBand: true, mic: mic, micRequired: false) == .outOfBand)
    }

    // Demo Radio never captures the mic, so permission doesn't gate it.
    @Test(arguments: [MicPermission.undetermined, .denied, .granted])
    func demoIgnoresMic(mic: MicPermission) {
        #expect(PTTGate.decide(outOfBand: false, mic: mic, micRequired: false) == .key)
    }

    @Test func mapsSystemPermission() {
        #expect(MicPermission(.granted) == .granted)
        #expect(MicPermission(.denied) == .denied)
        #expect(MicPermission(.undetermined) == .undetermined)
    }
}
