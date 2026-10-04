import Testing
@testable import KV4P_HT

struct CaptionTimelineTests {

    @Test func volatileReplacesAndFinalAppends() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        _ = t.apply(text: "This is", start: 0.1, isFinal: false)
        let v = t.apply(text: "This is the National", start: 0.1, isFinal: false)
        #expect(v?.text == "This is the National")
        _ = t.apply(text: "This is the National Weather Service.", start: 0.1, isFinal: true)
        let next = t.apply(text: "Winds", start: 4.0, isFinal: false)
        #expect(next?.id == 1)
        #expect(next?.text == "This is the National Weather Service. Winds")
    }

    // The old recognizer's bug: text after a pause must not wipe earlier
    // sentences on the same line.
    @Test func finalsAccumulateAcrossPauses() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        _ = t.apply(text: "First sentence.", start: 0.2, isFinal: true)
        _ = t.apply(text: "Second sentence.", start: 6.0, isFinal: true)
        let r = t.apply(text: "Third", start: 70.0, isFinal: false)
        #expect(r?.text == "First sentence. Second sentence. Third")
    }

    @Test func finalClearsVolatile() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        _ = t.apply(text: "Copy tha", start: 0.1, isFinal: false)
        let r = t.apply(text: "Copy that.", start: 0.1, isFinal: true)
        #expect(r?.text == "Copy that.")
    }

    // A late final for an earlier transmission lands on its own line, not
    // on the line currently receiving.
    @Test func resultsRouteByStartTime() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        t.end(at: 3)
        t.begin(id: 2, at: 3)
        _ = t.apply(text: "Second", start: 3.2, isFinal: false)
        let late = t.apply(text: "First transmission.", start: 0.4, isFinal: true)
        #expect(late?.id == 1)
        #expect(late?.text == "First transmission.")
        #expect(t.segments.last?.text == "Second")
    }

    @Test func toleratesWordStartJustBeforeSegment() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        t.begin(id: 2, at: 3)
        let r = t.apply(text: "Hello", start: 2.98, isFinal: false)
        #expect(r?.id == 2)
    }

    @Test func beginClosesOpenSegment() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 0)
        t.begin(id: 2, at: 5)
        #expect(t.segments.first?.end == 5)
        #expect(t.segments.last?.end == nil)
    }

    @Test func resultBeforeAllSegmentsIsDropped() {
        var t = CaptionTimeline()
        t.begin(id: 1, at: 10)
        let r = t.apply(text: "x", start: 1, isFinal: true)
        #expect(r == nil)
    }

    @Test func prunesOldSegments() {
        var t = CaptionTimeline(maxSegments: 3)
        for i in 0..<5 { t.begin(id: i, at: Double(i)) }
        #expect(t.segments.map(\.id) == [2, 3, 4])
    }

    @Test func joinTrimsLeadingSpace() {
        #expect(CaptionTimeline.join("Hello.", " World.") == "Hello. World.")
        #expect(CaptionTimeline.join("", " World.") == "World.")
    }
}
