import Foundation

// On-device log of finalized caption lines, kept when Settings › Save
// transcripts is on. Entries are keyed by the caption line's ID so a late
// recognizer result for an already-saved line updates it in place. Oldest
// entries drop past `maxEntries`.
nonisolated struct TranscriptEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let freq: Float
    // Memory channel name when the frequency matched a memory; absent in
    // entries saved before names were recorded.
    var channel: String? = nil
    var text: String

    // Memory name, or the frequency when not on a memory.
    var channelLabel: String {
        if let channel, !channel.isEmpty { return channel }
        return TranscriptLog.freqString(freq)
    }
}

nonisolated struct TranscriptLog: Equatable {
    static let defaultMaxEntries = 2000

    private(set) var entries: [TranscriptEntry] = []
    let maxEntries: Int

    init(entries: [TranscriptEntry] = [], maxEntries: Int = defaultMaxEntries) {
        self.maxEntries = maxEntries
        self.entries = entries
        trim()
    }

    // Adds the entry, or replaces the text of the one with the same ID.
    // Blank text is ignored (and removes an existing entry).
    mutating func upsert(_ entry: TranscriptEntry) {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            if text.isEmpty { entries.remove(at: i) } else { entries[i].text = text }
            return
        }
        guard !text.isEmpty else { return }
        var entry = entry
        entry.text = text
        // Keep chronological order even if a late line finalizes out of order.
        let i = entries.lastIndex(where: { $0.date <= entry.date }).map { $0 + 1 } ?? 0
        entries.insert(entry, at: i)
        trim()
    }

    mutating func remove(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    // Case- and diacritic-insensitive match on text or frequency.
    func search(_ query: String) -> [TranscriptEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.channel?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || Self.freqString($0.freq).hasPrefix(q)
        }
    }

    // Plain-text export, one line per transmission.
    static func exportText(_ entries: [TranscriptEntry],
                           timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.map { e in
            let channel = e.channel.map { $0.isEmpty ? "" : " (\($0))" } ?? ""
            return "\(f.string(from: e.date))  \(freqString(e.freq)) MHz\(channel)  \(e.text)"
        }
            .joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    static func freqString(_ freq: Float) -> String {
        String(format: "%.3f", freq)
    }

    private mutating func trim() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Storage

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "transcripts.json")
    }

    static func load(from url: URL = defaultURL) -> TranscriptLog {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data)
        else { return TranscriptLog() }
        return TranscriptLog(entries: entries)
    }

    func save(to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("[Transcripts] save failed: \(error)")
        }
    }
}
