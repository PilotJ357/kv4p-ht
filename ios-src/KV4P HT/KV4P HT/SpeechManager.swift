import Speech
import AVFoundation
import Synchronization

// Live captions on SpeechAnalyzer + SpeechTranscriber: one long-running,
// on-device-only session while captions are listening. Audio is fed only
// while a transmission is being received (startSegment/endSegment), and
// each transmission's results are routed to its own caption line by audio
// time (CaptionTimeline). No per-request time limit, so no rolling restarts.
@MainActor
class SpeechManager {
    private var localeIdentifier = "en-US"
    // nil until checked; false when SpeechTranscriber can't do the language.
    private var localeSupported: Bool?
    private var sessionTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    // Session generation; results and failures from a stopped session are
    // ignored.
    private var sessionID = 0
    private var timeline = CaptionTimeline()
    private var liveSegmentID: Int?
    private var nextSegmentID = 0
    // Transmission end that arrived before the analyzer was ready.
    private var pendingFinalize: (time: CMTime, segmentID: Int)?
    private let feed = AudioFeed()
    // Audio a caption line may span before rolling over mid-transmission.
    private static let maxLineDuration: TimeInterval = 20

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

    // Text for a caption line changed.
    var onPartialResult: ((Int, String) -> Void)?
    // A caption line's transmission ended and its text is final.
    var onSegmentFinalized: ((Int) -> Void)?
    // A long transmission rolled over to a new caption line (old, new); the
    // old line's text is final.
    var onSegmentSplit: ((Int, Int) -> Void)?
    // The analyzer session failed; captions must be restarted.
    var onSessionFailed: (() -> Void)?
    // Language support became known (supportsOnDeviceRecognition changed).
    var onAvailabilityChanged: (() -> Void)?

    func configure(language: String) {
        let id = Self.mapLanguage(language)
        guard id != localeIdentifier || localeSupported == nil else { return }
        localeIdentifier = id
        localeSupported = nil
        stopSession()
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

    // SpeechTranscriber only runs on-device; it's unavailable on hardware
    // without the neural engine support, or for unsupported languages.
    var supportsOnDeviceRecognition: Bool {
        SpeechTranscriber.isAvailable && localeSupported != false
    }

    // Loads the model ahead of the first transmission. Idempotent.
    func startSession() {
        guard sessionTask == nil, authorizationStatus == .authorized,
              supportsOnDeviceRecognition else { return }
        sessionID += 1
        let id = sessionID
        // A new session's audio clock starts at zero.
        timeline = CaptionTimeline()
        let chunks = feed.attach()
        sessionTask = Task { [weak self] in
            await self?.runSession(id: id, chunks: chunks)
        }
    }

    func stopSession() {
        endSegment()
        feed.detach()
        sessionTask?.cancel()
        sessionTask = nil
        if let pending = pendingFinalize {
            pendingFinalize = nil
            onSegmentFinalized?(pending.segmentID)
        }
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }

    func stopAll() {
        stopSession()
    }

    // Starts feeding a new transmission. Returns its caption line's ID, or
    // nil when captions can't run right now.
    @discardableResult
    func startSegment() -> Int? {
        startSession()
        guard sessionTask != nil else { return nil }
        endSegment()
        nextSegmentID += 1
        let segmentID = nextSegmentID
        let start = feed.startRecording()
        timeline.begin(id: segmentID, at: start.seconds)
        liveSegmentID = segmentID
        return segmentID
    }

    nonisolated func feedSamples(_ samples: [Float], count: Int) {
        feed.append(samples, count: count)
    }

    // Stops feeding and asks the analyzer to finalize everything received,
    // so the line's last words show without waiting for more audio.
    func endSegment() {
        guard let segmentID = liveSegmentID else { return }
        liveSegmentID = nil
        let end = feed.stopRecording()
        timeline.end(at: end.seconds)
        guard let analyzer else {
            pendingFinalize = (end, segmentID)
            return
        }
        finalize(analyzer, through: end, segmentID: segmentID)
    }

    private func finalize(_ analyzer: SpeechAnalyzer, through time: CMTime, segmentID: Int) {
        Task { [weak self] in
            try? await analyzer.finalize(through: time)
            self?.onSegmentFinalized?(segmentID)
        }
    }

    private func runSession(id: Int, chunks: AsyncStream<AudioFeed.Chunk>) async {
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier)) else {
                localeSupported = false
                sessionTask = nil
                onAvailabilityChanged?()
                return
            }
            if localeSupported != true {
                localeSupported = true
            }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            let modules: [any SpeechModule] = [transcriber]

            // The model is a system asset; download it on first use.
            if await AssetInventory.status(forModules: modules) < .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                print("[Captions] downloading speech model for \(locale.identifier)")
                try await request.downloadAndInstall()
            }
            _ = try? await AssetInventory.reserve(locale: locale)

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw CaptionsError.noAudioFormat
            }
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .lingering))
            let context = AnalysisContext()
            context.contextualStrings[.general] = Self.hamVocab
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)

            let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: inputs)
            try Task.checkCancellation()
            self.analyzer = analyzer
            print("[Captions] analyzer ready (\(locale.identifier), \(format.sampleRate) Hz)")

            let pump = Task.detached {
                let converter = AudioFeed.Converter(target: format)
                for await chunk in chunks {
                    if let input = converter.input(for: chunk) {
                        inputContinuation.yield(input)
                    }
                }
                inputContinuation.finish()
            }
            defer { pump.cancel() }

            if let pending = pendingFinalize {
                pendingFinalize = nil
                finalize(analyzer, through: pending.time, segmentID: pending.segmentID)
            }

            for try await result in transcriber.results {
                guard id == sessionID else { break }
                let text = String(result.text.characters)
                if let line = timeline.apply(text: text, start: result.range.start.seconds,
                                             isFinal: result.isFinal) {
                    onPartialResult?(line.id, line.text)
                    if result.isFinal, line.id == liveSegmentID,
                       timeline.splitIfLong(newID: nextSegmentID + 1,
                                            at: result.range.end.seconds,
                                            maxDuration: Self.maxLineDuration) {
                        nextSegmentID += 1
                        liveSegmentID = nextSegmentID
                        onSegmentSplit?(line.id, nextSegmentID)
                    }
                }
            }
            // Results only end when the session is stopped; anything else
            // leaves captions dead, so treat it as a failure.
            throw CaptionsError.sessionEnded
        } catch {
            guard id == sessionID, !Task.isCancelled else { return }
            print("[Captions] analyzer session failed: \(error)")
            for segmentID in [liveSegmentID, pendingFinalize?.segmentID].compactMap({ $0 }) {
                onSegmentFinalized?(segmentID)
            }
            liveSegmentID = nil
            pendingFinalize = nil
            feed.detach()
            sessionTask = nil
            analyzer = nil
            onSessionFailed?()
        }
    }

    private enum CaptionsError: Error {
        case noAudioFormat
        case sessionEnded
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

// Hands received audio (BLE queue) to the analyzer session. Only audio fed
// while recording advances the analyzer's timeline, so time positions are
// cumulative received-audio time at the wire rate.
nonisolated final class AudioFeed: Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let start: Int64
    }

    static let sampleRate: Double = 16000

    private struct State {
        var continuation: AsyncStream<Chunk>.Continuation?
        var recording = false
        var samplesFed: Int64 = 0
    }

    private let state = Mutex(State())

    func attach() -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream<Chunk>.makeStream()
        state.withLock {
            $0.continuation?.finish()
            $0.continuation = continuation
            $0.recording = false
            $0.samplesFed = 0
        }
        return stream
    }

    func detach() {
        state.withLock {
            $0.continuation?.finish()
            $0.continuation = nil
            $0.recording = false
        }
    }

    func startRecording() -> CMTime {
        state.withLock {
            $0.recording = true
            return Self.time($0.samplesFed)
        }
    }

    func stopRecording() -> CMTime {
        state.withLock {
            $0.recording = false
            return Self.time($0.samplesFed)
        }
    }

    func append(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        state.withLock {
            guard $0.recording, let continuation = $0.continuation else { return }
            continuation.yield(Chunk(samples: Array(samples.prefix(count)), start: $0.samplesFed))
            $0.samplesFed += Int64(count)
        }
    }

    static func time(_ samples: Int64) -> CMTime {
        CMTime(value: samples, timescale: CMTimeScale(sampleRate))
    }

    // Converts 16 kHz mono Float32 chunks to the analyzer's format. Used
    // from a single task only.
    final class Converter {
        private let source = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioFeed.sampleRate,
            channels: 1, interleaved: false)!
        private let target: AVAudioFormat
        private let converter: AVAudioConverter?

        init(target: AVAudioFormat) {
            self.target = target
            converter = target == source ? nil : AVAudioConverter(from: source, to: target)
        }

        func input(for chunk: Chunk) -> AnalyzerInput? {
            let count = chunk.samples.count
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData else { return nil }
            buffer.frameLength = AVAudioFrameCount(count)
            chunk.samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: count) }
            let startTime = AudioFeed.time(chunk.start)
            guard let converter else {
                return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
            }
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount((Double(count) * ratio).rounded(.up)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0 else { return nil }
            return AnalyzerInput(buffer: output, bufferStartTime: startTime)
        }
    }
}
