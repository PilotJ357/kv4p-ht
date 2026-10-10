import Foundation

/// Parses repeater lists the user exports themselves: RepeaterBook's US and
/// rest-of-world CSV downloads (same layouts Android's FindRepeatersActivity
/// reads) and CHIRP CSV. Local files only — the app never fetches them.
nonisolated enum RepeaterCSV {

    enum Format: Equatable {
        case repeaterBookUS, repeaterBookWorld, chirp

        var isRepeaterBook: Bool { self != .chirp }

        var label: String {
            switch self {
            case .repeaterBookUS:    return "RepeaterBook (US)"
            case .repeaterBookWorld: return "RepeaterBook"
            case .chirp:             return "CHIRP"
            }
        }
    }

    struct Entry: Equatable {
        var name: String
        var freq: Float      // RX (repeater output), MHz
        var offset: Float    // signed MHz, 0 = simplex
        var txTone: Float    // Hz, 0 = none
        var rxTone: Float    // Hz, 0 = none
        var narrow: Bool = false
        var notes: String = ""
    }

    struct Parsed {
        var format: Format
        var entries: [Entry]
        var skipped: Int     // data rows with no usable frequency
    }

    enum ParseError: LocalizedError, Equatable {
        case unreadable, unrecognized, noRepeaters

        var errorDescription: String? {
            switch self {
            case .unreadable:   return "The file isn't readable text."
            case .unrecognized: return "This isn't a RepeaterBook or CHIRP CSV export."
            case .noRepeaters:  return "No repeaters were found in this file."
            }
        }
    }

    // MARK: Entry point

    static func parse(_ data: Data) throws -> Parsed {
        guard let text = decode(data) else { throw ParseError.unreadable }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Parsed {
        let rows = records(text)
            .map { fields($0) }
            .filter { !$0.allSatisfy(\.isEmpty) }
        guard let header = rows.first else { throw ParseError.noRepeaters }
        let names = header.map { $0.lowercased() }

        let format: Format
        if names.starts(with: ["freq", "input", "offset", "tone", "location"]) {
            format = .repeaterBookUS
        } else if names.starts(with: ["output freq", "input freq", "offset", "uplink tone"]) {
            format = .repeaterBookWorld
        } else if ["frequency", "duplex", "offset", "name"].allSatisfy(names.contains) {
            format = .chirp
        } else {
            throw ParseError.unrecognized
        }

        var entries: [Entry] = []
        var skipped = 0
        for cols in rows.dropFirst() {
            let entry: Entry?
            switch format {
            case .repeaterBookUS:    entry = usEntry(cols)
            case .repeaterBookWorld: entry = worldEntry(cols, hasDownlinkTone: names.count > 4 && names[4] == "downlink tone")
            case .chirp:             entry = chirpEntry(cols, header: names)
            }
            if let entry { entries.append(entry) } else { skipped += 1 }
        }
        guard !entries.isEmpty else { throw ParseError.noRepeaters }
        return Parsed(format: format, entries: entries, skipped: skipped)
    }

    /// UTF-8, falling back to Windows-1252 for older spreadsheet exports.
    static func decode(_ data: Data) -> String? {
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        if text?.first == "\u{FEFF}" { text?.removeFirst() }
        return text
    }

    // MARK: RepeaterBook

    // Freq,Input,Offset,Tone,Location,State,County,Call,Use,Miles,Bearing,Degrees
    private static func usEntry(_ cols: [String]) -> Entry? {
        guard var e = commonEntry(cols) else { return nil }
        e.name = displayName(call: col(cols, 7), location: col(cols, 4))
        e.notes = joined(col(cols, 6), col(cols, 5), col(cols, 8))
        return e
    }

    // Output Freq,Input Freq,Offset,Uplink Tone,Downlink Tone,Call,Location,County,State,…
    private static func worldEntry(_ cols: [String], hasDownlinkTone: Bool) -> Entry? {
        guard var e = commonEntry(cols) else { return nil }
        if hasDownlinkTone { e.rxTone = normalizeTone(col(cols, 4)) }
        e.name = displayName(call: col(cols, 5), location: col(cols, 6))
        e.notes = joined(col(cols, 7), col(cols, 8))
        return e
    }

    /// Output, input, offset and uplink tone sit in the first four columns of both layouts.
    private static func commonEntry(_ cols: [String]) -> Entry? {
        guard let freq = Float(col(cols, 0)), freq > 0 else { return nil }
        // The input column is the exact TX frequency (odd splits included);
        // the offset column is the fallback, as on Android.
        let offset: Float
        if let input = Float(col(cols, 1)), input > 0 {
            offset = input - freq
        } else {
            offset = Float(col(cols, 2)) ?? 0
        }
        return Entry(name: "", freq: freq, offset: rounded(offset),
                     txTone: normalizeTone(col(cols, 3)), rxTone: 0)
    }

    private static func displayName(call: String, location: String) -> String {
        [call, location].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: CHIRP

    // Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,…,Mode,…,Comment
    private static func chirpEntry(_ cols: [String], header: [String]) -> Entry? {
        func value(_ name: String) -> String {
            header.firstIndex(of: name.lowercased()).map { col(cols, $0) } ?? ""
        }
        guard let freq = Float(value("Frequency")), freq > 0 else { return nil }

        let shift = Float(value("Offset")) ?? 0
        var offset: Float
        switch value("Duplex").lowercased() {
        case "+":     offset = shift
        case "-":     offset = -shift
        case "split": offset = shift > 0 ? shift - freq : 0  // Offset holds the TX frequency
        default:      offset = 0                              // "", "off"
        }
        offset = rounded(offset)

        let rTone = normalizeTone(value("rToneFreq"))
        let cTone = normalizeTone(value("cToneFreq"))
        var tx: Float = 0, rx: Float = 0
        switch value("Tone").lowercased() {
        case "tone": tx = rTone
        case "tsql": tx = cTone; rx = cTone
        case "cross" where value("CrossMode").lowercased() == "tone->tone":
            tx = rTone; rx = cTone
        default: break  // DTCS isn't supported by the radio
        }

        let name = value("Name")
        return Entry(name: name.isEmpty ? String(format: "%.3f", freq) : name,
                     freq: freq, offset: offset, txTone: tx, rxTone: rx,
                     narrow: value("Mode").uppercased() == "NFM",
                     notes: value("Comment"))
    }

    // MARK: Tones

    /// Port of Android's ToneHelper.normalizeTone: the nearest CTCSS tone within
    /// 1 Hz, else 0. "CSQ", DCS codes and 0/1 placeholders mean no tone.
    static func normalizeTone(_ text: String) -> Float {
        guard let hz = Float(text.trimmingCharacters(in: .whitespaces)), hz != 0, hz != 1 else { return 0 }
        let nearest = CTCSS_TONES.min { abs($0 - hz) < abs($1 - hz) }
        guard let nearest, abs(nearest - hz) <= 1.0 else { return 0 }
        return nearest
    }

    // MARK: CSV splitting

    /// Splits on newlines outside quotes, so a quoted field may span lines.
    static func records(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        // unicodeScalars: Swift folds "\r\n" into one Character.
        for ch in text.unicodeScalars {
            if ch == "\"" { inQuotes.toggle() }
            if ch == "\n" && !inQuotes {
                out.append(cur)
                cur = ""
            } else {
                cur.unicodeScalars.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Splits a record on commas outside quotes. Quotes are dropped and `""`
    /// inside a quoted field is a literal quote. Line breaks inside a field
    /// become spaces.
    static func fields(_ record: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        let chars = Array(record.unicodeScalars)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" {
                    cur.unicodeScalars.append(ch)
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                out.append(clean(cur))
                cur = ""
            } else {
                cur.unicodeScalars.append(ch)
            }
            i += 1
        }
        out.append(clean(cur))
        return out
    }

    private static func clean(_ field: String) -> String {
        field.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func col(_ cols: [String], _ i: Int) -> String {
        i < cols.count ? cols[i] : ""
    }

    private static func joined(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Float subtraction leaves noise like 0.6000061; keep 100 Hz resolution.
    private static func rounded(_ mhz: Float) -> Float {
        (mhz * 10_000).rounded() / 10_000
    }
}

extension RepeaterCSV.Entry {
    func memory(group: String) -> Memory {
        Memory(name: name, group: group, freq: freq, offset: offset,
               plTone: txTone, rxTone: rxTone, squelch: 2,
               isRepeater: offset != 0, notes: notes,
               bandwidth: narrow ? 1 : 0)
    }
}
