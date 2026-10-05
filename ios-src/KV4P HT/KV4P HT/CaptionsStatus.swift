import Speech
import UIKit

// What live captions can do right now. Derived from the user's toggle, the
// speech-recognition permission, and on-device support; only `.listening`
// runs the recognizer. Captions never fall back to server recognition.
nonisolated enum CaptionsStatus: Equatable {
    case off                 // user turned Live captions off
    case needsPermission     // permission not asked yet
    case denied              // user declined speech recognition
    case restricted          // blocked by Screen Time / MDM
    case unavailable         // no on-device recognition for the language
    case listening

    static func resolve(enabled: Bool,
                        authorization: SFSpeechRecognizerAuthorizationStatus,
                        supportsOnDevice: Bool) -> CaptionsStatus {
        guard enabled else { return .off }
        // Permission first: on-device support is only trusted once the
        // recognizer is authorized, and the prompt must not be gated on it.
        switch authorization {
        case .authorized:    return supportsOnDevice ? .listening : .unavailable
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .needsPermission
        @unknown default:    return .needsPermission
        }
    }

    // Whether the Settings app can fix this (user-changeable permission).
    var opensSettings: Bool { self == .denied }

    // This app's page in the Settings app, where the Speech Recognition
    // permission lives.
    @MainActor static let appSettingsURL = URL(string: UIApplication.openSettingsURLString)!

    // User-facing explanation; nil when captions are working.
    func message(language: String) -> String? {
        switch self {
        case .off:
            return "Live captions are off."
        case .needsPermission:
            return "Allow speech recognition to see live captions."
        case .denied:
            return "Speech recognition access is off for Pocket HT. Turn it on in Settings to see live captions."
        case .restricted:
            return "Speech recognition is restricted on this device."
        case .unavailable:
            return "This device doesn't support on-device speech recognition for \(language). Live captions only run on-device, so radio audio is never sent to Apple's servers."
        case .listening:
            return nil
        }
    }
}
