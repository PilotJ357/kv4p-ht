import Foundation

// Routes SpeechTranscriber results to caption lines. The analyzer runs one
// long session; audio is only fed while a transmission is being received,
// so its timeline is cumulative received audio. Each transmission (caption
// line) owns the span of that timeline fed while it was open, and a result
// belongs to the line whose span contains the result's start.
//
// Within a line, finalized results append and the latest volatile result
// replaces the previous one (SpeechTranscriber's reporting model).
nonisolated struct CaptionTimeline {
    struct Segment: Equatable {
        let id: Int
        let start: TimeInterval
        var end: TimeInterval?
        var finalized = ""
        var volatile = ""

        var text: String { CaptionTimeline.join(finalized, volatile) }
    }

    private(set) var segments: [Segment] = []
    let maxSegments: Int

    init(maxSegments: Int = 100) {
        self.maxSegments = maxSegments
    }

    mutating func begin(id: Int, at start: TimeInterval) {
        end(at: start)
        segments.append(Segment(id: id, start: start))
        if segments.count > maxSegments {
            segments.removeFirst(segments.count - maxSegments)
        }
    }

    mutating func end(at time: TimeInterval) {
        guard let last = segments.indices.last, segments[last].end == nil else { return }
        segments[last].end = time
    }

    // Returns the updated line, or nil when the result predates every
    // remembered segment.
    mutating func apply(text: String, start: TimeInterval, isFinal: Bool) -> (id: Int, text: String)? {
        // Word boundaries can land a hair before a segment's first sample.
        let tolerance = 0.05
        guard let i = segments.lastIndex(where: { $0.start <= start + tolerance }) else { return nil }
        if isFinal {
            segments[i].finalized = Self.join(segments[i].finalized, text)
            segments[i].volatile = ""
        } else {
            segments[i].volatile = text
        }
        return (segments[i].id, segments[i].text)
    }

    static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
