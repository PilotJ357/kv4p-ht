import Speech
import AVFoundation

@MainActor
class SpeechManager {
    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var segmentTimer: Timer?
    // Segment currently accepting audio, if any.
    private var liveSegmentID: Int?
    private var segmentGeneration = 0
    // Segments whose audio has ended but whose final result hasn't arrived;
    // the timeout cancels a task that never reports back.
    private var drainingSegments: [Int: (task: SFSpeechRecognitionTask, timeout: Task<Void, Never>)] = [:]
    // Thread-safe reference for feeding samples from BLE queue
    nonisolated(unsafe) private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private static let rollingRestartSeconds: TimeInterval = 55
    private static let drainTimeout: Duration = .seconds(5)
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

    // All callbacks carry the segment ID returned by startSegment(), so
    // results that arrive after a newer segment started still land on
    // their own caption line.
    var onPartialResult: ((Int, String) -> Void)?
    // The segment produced its last result (or was abandoned).
    var onSegmentFinalized: ((Int) -> Void)?
    // A rolling restart started this new segment.
    var onRollingRestart: ((Int) -> Void)?
    // The live segment ended on its own (final result or error), not via
    // endSegment()/rollingRestart().
    var onSegmentEnded: ((CaptionRestartPolicy.Ending) -> Void)?

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

    var isSegmentActive: Bool { liveSegmentID != nil }

    // Captions are on-device only: without local support SFSpeechRecognizer
    // would stream received audio to Apple's servers, so we don't run at all.
    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    // Returns the new segment's ID, or nil when the recognizer can't start
    // right now (not authorized, unavailable, or on-device model not ready).
    @discardableResult
    func startSegment() -> Int? {
        guard authorizationStatus == .authorized,
              let recognizer, recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }
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
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = result == nil && error != nil
            Task { @MainActor in
                guard let self, self.isTracked(segmentID) else { return }
                if let text { self.onPartialResult?(segmentID, text) }
                if isFinal {
                    self.segmentDidEnd(segmentID, .finished)
                } else if failed {
                    self.segmentDidEnd(segmentID, .failed)
                }
            }
        }

        liveSegmentID = segmentID

        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(
            withTimeInterval: Self.rollingRestartSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rollingRestart()
            }
        }
        return segmentID
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

    // Stops feeding the live segment and lets the recognizer finish the
    // audio it already has. Cancelling here would discard that buffered
    // tail, losing the end of every transmission.
    func endSegment() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        activeRequest = nil
        guard let segmentID = liveSegmentID, let task = currentTask else {
            liveSegmentID = nil
            return
        }
        currentRequest?.endAudio()
        task.finish()
        currentRequest = nil
        currentTask = nil
        liveSegmentID = nil
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.drainTimeout)
            guard !Task.isCancelled, let self,
                  let draining = self.drainingSegments.removeValue(forKey: segmentID) else { return }
            draining.task.cancel()
            self.onSegmentFinalized?(segmentID)
        }
        drainingSegments[segmentID] = (task, timeout)
    }

    func stopAll() {
        endSegment()
        recognizer = nil
    }

    private func rollingRestart() {
        guard liveSegmentID != nil else { return }
        endSegment()
        if let segmentID = startSegment() {
            onRollingRestart?(segmentID)
        } else {
            onSegmentEnded?(.startFailed)
        }
    }

    private func isTracked(_ segmentID: Int) -> Bool {
        segmentID == liveSegmentID || drainingSegments[segmentID] != nil
    }

    private func segmentDidEnd(_ segmentID: Int, _ ending: CaptionRestartPolicy.Ending) {
        if segmentID == liveSegmentID {
            segmentTimer?.invalidate()
            segmentTimer = nil
            activeRequest = nil
            currentRequest = nil
            currentTask = nil
            liveSegmentID = nil
            onSegmentFinalized?(segmentID)
            onSegmentEnded?(ending)
        } else if let draining = drainingSegments.removeValue(forKey: segmentID) {
            draining.timeout.cancel()
            onSegmentFinalized?(segmentID)
        }
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
