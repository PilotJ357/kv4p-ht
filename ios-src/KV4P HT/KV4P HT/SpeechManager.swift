import Speech
import AVFoundation

@MainActor
class SpeechManager {
    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var segmentTimer: Timer?
    private var isRecognizing = false
    private var segmentGeneration = 0
    // Thread-safe reference for feeding samples from BLE queue
    nonisolated(unsafe) private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private static let rollingRestartSeconds: TimeInterval = 55
    private static let hamVocab = [
        "CQ", "QSO", "QTH", "QSL", "QRZ", "QRM", "QRN", "QRP", "QRO",
        "73", "88", "roger", "copy", "over", "out", "break", "breaker",
        "mayday", "pan-pan", "wilco", "affirmative", "negative",
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
        "golf", "hotel", "india", "juliet", "kilo", "lima", "mike",
        "november", "oscar", "papa", "quebec", "romeo", "sierra",
        "tango", "uniform", "victor", "whiskey", "x-ray", "yankee", "zulu",
        "simplex", "repeater", "duplex", "squelch", "kerchunk",
        "ham", "amateur", "frequency", "megahertz", "kilohertz"
    ]

    var onPartialResult: ((String) -> Void)?
    var onSegmentFinalized: (() -> Void)?
    var onRollingRestart: (() -> Void)?
    // The recognizer ended a segment on its own (final result or error),
    // not via endSegment()/rollingRestart().
    var onSegmentEnded: (() -> Void)?

    func configure(language: String) {
        let localeId = Self.mapLanguage(language)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
    }

    func requestAuthorization(completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    var isSegmentActive: Bool { isRecognizing }

    // Captions are on-device only: without local support SFSpeechRecognizer
    // would stream received audio to Apple's servers, so we don't run at all.
    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // Returns false when the recognizer can't start right now (not
    // authorized, unavailable, or on-device model not ready).
    @discardableResult
    func startSegment() -> Bool {
        guard authorizationStatus == .authorized,
              let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return false }
        endSegment()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Self.hamVocab
        currentRequest = request
        activeRequest = request

        segmentGeneration += 1
        let segmentID = segmentGeneration
        currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    guard segmentID == self.segmentGeneration else { return }
                    self.onPartialResult?(text)
                }
                if result.isFinal {
                    Task { @MainActor in
                        self.finalizeCurrentSegment(segmentID)
                    }
                }
            } else if error != nil {
                Task { @MainActor in
                    self.finalizeCurrentSegment(segmentID)
                }
            }
        }

        isRecognizing = true

        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(
            withTimeInterval: Self.rollingRestartSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rollingRestart()
            }
        }
        return true
    }

    nonisolated func feedSamples(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        let fmt = audioFormat
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        if let channelData = pcmBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: count)
            }
        }
        activeRequest?.append(pcmBuffer)
    }

    func endSegment() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        activeRequest = nil
        guard isRecognizing else { return }
        currentRequest?.endAudio()
        currentRequest = nil
        currentTask?.cancel()
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
    }

    func stopAll() {
        activeRequest = nil
        endSegment()
        recognizer = nil
    }

    private func rollingRestart() {
        guard isRecognizing else { return }
        activeRequest = nil
        currentRequest?.endAudio()
        currentRequest = nil
        currentTask?.cancel()
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
        if startSegment() {
            onRollingRestart?()
        } else {
            onSegmentEnded?()
        }
    }

    private func finalizeCurrentSegment(_ segmentID: Int) {
        // A cancelled task reports its error after a newer segment may have
        // started; only the current segment's task may end it.
        guard isRecognizing, segmentID == segmentGeneration else { return }
        segmentTimer?.invalidate()
        segmentTimer = nil
        activeRequest = nil
        currentRequest = nil
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
        onSegmentEnded?()
    }

    private static func mapLanguage(_ language: String) -> String {
        switch language {
        case "English (US)": return "en-US"
        case "English (UK)": return "en-GB"
        case "English (AU)": return "en-AU"
        case "Spanish":      return "es-ES"
        case "French":       return "fr-FR"
        case "German":       return "de-DE"
        case "Japanese":     return "ja-JP"
        case "Portuguese":   return "pt-BR"
        default:             return "en-US"
        }
    }
}
