import Foundation
import Testing
@testable import KV4P_HT

struct TranscriptLogTests {

    private func entry(_ text: String, at t: TimeInterval, freq: Float = 146.52,
                       id: UUID = UUID()) -> TranscriptEntry {
        TranscriptEntry(id: id, date: Date(timeIntervalSince1970: t), freq: freq, text: text)
    }

    @Test func upsertAddsTrimmedAndSkipsBlank() {
        var log = TranscriptLog()
        log.upsert(entry("  hello  ", at: 0))
        log.upsert(entry("   ", at: 1))
        #expect(log.entries.map(\.text) == ["hello"])
    }

    @Test func upsertReplacesByID() {
        var log = TranscriptLog()
        let id = UUID()
        log.upsert(entry("this is", at: 0, id: id))
        log.upsert(entry("this is KV4P", at: 0, id: id))
        #expect(log.entries.count == 1)
        #expect(log.entries[0].text == "this is KV4P")
        log.upsert(entry("", at: 0, id: id))
        #expect(log.entries.isEmpty)
    }

    @Test func keepsChronologicalOrder() {
        var log = TranscriptLog()
        log.upsert(entry("b", at: 2))
        log.upsert(entry("a", at: 1))
        log.upsert(entry("c", at: 3))
        #expect(log.entries.map(\.text) == ["a", "b", "c"])
    }

    @Test func capDropsOldest() {
        var log = TranscriptLog(maxEntries: 2)
        log.upsert(entry("a", at: 1))
        log.upsert(entry("b", at: 2))
        log.upsert(entry("c", at: 3))
        #expect(log.entries.map(\.text) == ["b", "c"])
    }

    @Test func searchMatchesTextAndFrequency() {
        var log = TranscriptLog()
        log.upsert(entry("CQ CQ this is KV4P", at: 1, freq: 146.52))
        log.upsert(entry("Net control, café", at: 2, freq: 147.06))
        #expect(log.search("kv4p").map(\.text) == ["CQ CQ this is KV4P"])
        #expect(log.search("cafe").count == 1)
        #expect(log.search("147.0").map(\.text) == ["Net control, café"])
        #expect(log.search(" ").count == 2)
        #expect(log.search("nothing").isEmpty)
    }

    @Test func removeIDs() {
        var log = TranscriptLog()
        let a = entry("a", at: 1), b = entry("b", at: 2)
        log.upsert(a); log.upsert(b)
        log.remove(ids: [a.id])
        #expect(log.entries.map(\.text) == ["b"])
    }

    @Test func exportFormat() {
        let text = TranscriptLog.exportText([entry("hello", at: 0, freq: 146.52)],
                                            timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == "1970-01-01 00:00:00  146.520 MHz  hello\n")
        #expect(TranscriptLog.exportText([]) == "")
    }

    @Test func saveAndLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "transcripts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var log = TranscriptLog()
        log.upsert(entry("hello", at: 5, freq: 446.0))
        log.save(to: url)
        let loaded = TranscriptLog.load(from: url)
        #expect(loaded.entries == log.entries)
        #expect(TranscriptLog.load(from: url.appending(path: "missing")).entries.isEmpty)
    }
}
