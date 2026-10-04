import Speech
import Testing
@testable import KV4P_HT

private func status(enabled: Bool = true,
                    _ auth: SFSpeechRecognizerAuthorizationStatus,
                    onDevice: Bool = true) -> CaptionsStatus {
    CaptionsStatus.resolve(enabled: enabled, authorization: auth, supportsOnDevice: onDevice)
}

struct CaptionsStatusTests {

    @Test func offWinsOverEverything() {
        for auth: SFSpeechRecognizerAuthorizationStatus in [.notDetermined, .denied, .restricted, .authorized] {
            #expect(status(enabled: false, auth) == .off)
            #expect(status(enabled: false, auth, onDevice: false) == .off)
        }
    }

    // Fresh install: captions default on, permission never asked. Must
    // surface as needing permission (so the sheet asks), not as idle.
    @Test func freshInstallNeedsPermission() {
        #expect(status(.notDetermined) == .needsPermission)
    }

    // The prompt isn't gated on on-device support, which may not be
    // reported until the recognizer is authorized.
    @Test func permissionCheckedBeforeOnDeviceSupport() {
        #expect(status(.notDetermined, onDevice: false) == .needsPermission)
        #expect(status(.denied, onDevice: false) == .denied)
        #expect(status(.restricted, onDevice: false) == .restricted)
    }

    @Test func authorizedRequiresOnDevice() {
        #expect(status(.authorized) == .listening)
        #expect(status(.authorized, onDevice: false) == .unavailable)
    }

    @Test func deniedAndRestricted() {
        #expect(status(.denied) == .denied)
        #expect(status(.restricted) == .restricted)
    }

    @Test func onlyDeniedOffersSettings() {
        #expect(CaptionsStatus.denied.opensSettings)
        for s: CaptionsStatus in [.off, .needsPermission, .restricted, .unavailable, .listening] {
            #expect(!s.opensSettings)
        }
    }

    @Test func messageOnlyWhenNotListening() {
        #expect(CaptionsStatus.listening.message(language: "English (US)") == nil)
        for s: CaptionsStatus in [.off, .needsPermission, .denied, .restricted, .unavailable] {
            #expect(s.message(language: "English (US)") != nil)
        }
        #expect(CaptionsStatus.unavailable.message(language: "Japanese")?.contains("Japanese") == true)
    }
}
