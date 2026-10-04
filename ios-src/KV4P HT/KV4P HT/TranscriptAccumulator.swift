import Foundation

// Builds one caption line's text from a recognition task's results.
//
// On iOS 17+ the on-device recognizer restarts its partial transcription
// after a pause in speech: the next partial holds only the new utterance,
// while the final result (at endAudio) holds the whole segment again.
// Showing each partial verbatim made earlier sentences vanish until the
// segment ended, so earlier utterances are committed here and kept.
nonisolated struct TranscriptAccumulator {
    // Utterances the recognizer has moved past.
    private(set) var committed = ""
    // The utterance the recognizer is still revising.
    private(set) var current = ""
    // Start time of the current utterance's first word, when reported.
    private var currentStart: TimeInterval?

    var text: String { Self.join(committed, current) }

    // `firstWordStart` is bestTranscription.segments.first?.timestamp;
    // partials may report 0 when timing isn't available.
    mutating func partial(_ newText: String, firstWordStart: TimeInterval?) -> String {
        let start = firstWordStart.flatMap { $0 > 0 ? $0 : nil }
        if Self.isRestart(previous: current, previousStart: currentStart,
                          next: newText, nextStart: start) {
            committed = Self.join(committed, current)
        }
        current = newText
        currentStart = start
        return text
    }

    // The final result normally covers the whole segment; prefer it then,
    // since it carries the recognizer's last corrections. If it only covers
    // the last utterance, keep what was committed.
    mutating func final(_ finalText: String) -> String {
        if Self.wordCount(finalText) * 10 >= Self.wordCount(text) * 7 {
            committed = ""
        }
        current = finalText
        currentStart = nil
        return text
    }

    static func isRestart(previous: String, previousStart: TimeInterval?,
                          next: String, nextStart: TimeInterval?) -> Bool {
        guard !previous.isEmpty, !next.isEmpty else { return false }
        // A revision of the same utterance keeps its first word's start
        // time; a new utterance starts later.
        if let previousStart, let nextStart {
            return nextStart > previousStart + 0.5
        }
        // No timing: a revision keeps the opening word and doesn't shrink
        // much; a restart drops back to a few words starting differently.
        let prevWords = words(previous)
        let nextWords = words(next)
        guard nextWords.count < prevWords.count else { return false }
        return prevWords.first != nextWords.first
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func wordCount(_ s: String) -> Int { words(s).count }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
