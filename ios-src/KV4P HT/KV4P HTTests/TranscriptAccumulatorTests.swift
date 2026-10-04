import Testing
@testable import KV4P_HT

struct TranscriptAccumulatorTests {

    @Test func revisionsReplaceCurrentUtterance() {
        var t = TranscriptAccumulator()
        _ = t.partial("This is", firstWordStart: 0.2)
        _ = t.partial("This is the", firstWordStart: 0.2)
        let text = t.partial("This is the National Weather Service", firstWordStart: 0.2)
        #expect(text == "This is the National Weather Service")
    }

    // The reported bug: after a pause the recognizer's partial restarts
    // with only the new utterance. The earlier sentence must stay.
    @Test func restartAfterPauseKeepsEarlierUtterance() {
        var t = TranscriptAccumulator()
        _ = t.partial("This is the National Weather Service.", firstWordStart: 0.2)
        let text = t.partial("Winds", firstWordStart: 4.1)
        #expect(text == "This is the National Weather Service. Winds")
        let text2 = t.partial("Winds out of the west", firstWordStart: 4.1)
        #expect(text2 == "This is the National Weather Service. Winds out of the west")
    }

    @Test func restartDetectedFromTextWithoutTiming() {
        var t = TranscriptAccumulator()
        _ = t.partial("Station identification follows", firstWordStart: 0)
        let text = t.partial("Winds", firstWordStart: 0)
        #expect(text == "Station identification follows Winds")
    }

    @Test func revisionWithoutTimingIsNotARestart() {
        var t = TranscriptAccumulator()
        _ = t.partial("Station identification follows", firstWordStart: nil)
        // Recognizer rewrites the tail, shrinking the text.
        let text = t.partial("Station ID", firstWordStart: nil)
        #expect(text == "Station ID")
    }

    // Final result normally holds the whole segment: use it as is.
    @Test func fullFinalReplacesAccumulated() {
        var t = TranscriptAccumulator()
        _ = t.partial("This is the National Weather Service", firstWordStart: 0.2)
        _ = t.partial("Winds west", firstWordStart: 4.1)
        let text = t.final("This is the National Weather Service. Winds west.")
        #expect(text == "This is the National Weather Service. Winds west.")
    }

    // If the final only covers the last utterance, keep earlier ones.
    @Test func partialFinalKeepsCommitted() {
        var t = TranscriptAccumulator()
        _ = t.partial("This is the National Weather Service", firstWordStart: 0.2)
        _ = t.partial("Winds west", firstWordStart: 4.1)
        let text = t.final("Winds west.")
        #expect(text == "This is the National Weather Service Winds west.")
    }

    @Test func finalWithoutPartials() {
        var t = TranscriptAccumulator()
        let text = t.final("Copy.")
        #expect(text == "Copy.")
    }
}
