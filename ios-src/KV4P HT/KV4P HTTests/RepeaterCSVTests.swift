import Foundation
import Testing
@testable import KV4P_HT

// Header layouts match what Android's FindRepeatersActivity.parseRepeaterList expects.
struct RepeaterCSVTests {

    static let us = """
    Freq,Input,Offset,Tone,Location,State,County,Call,Use,Miles,Bearing,Degrees\r
    146.94000,146.34000,-0.6,100.0,"Mt. Wilson, Los Angeles",California,Los Angeles,W6ABC,OPEN,4.2,NE,45\r
    147.24000,147.84000,+0.6,CSQ,"Pasadena
    JPL",California,Los Angeles,K6XYZ,OPEN,7.9,N,2\r
    442.10000,447.10000,+5.0,123.1,Glendale,California,Los Angeles,N6QQQ,OPEN,9.0,W,270\r

    """

    static let world = """
    Output Freq,Input Freq,Offset,Uplink Tone,Downlink Tone,Call,Location,County,State,Country,Distance,Direction
    145.6000,145.0000,-0.6,88.5,88.5,GB3XX,London,Greater London,England,United Kingdom,3.1,N
    433.0500,434.6500,1.6,,,DB0ABC,"Berlin ""Mitte""\",Berlin,Berlin,Germany,10,E
    """

    static let chirp = """
    Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,RxDtcsCode,CrossMode,Mode,TStep,Skip,Power,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE
    0,W6ABC,146.940000,-,0.600000,Tone,100.0,88.5,023,NN,023,Tone->Tone,FM,5.00,,50W,Mt Wilson,,,,
    1,TSQL RPT,147.240000,+,0.600000,TSQL,88.5,131.8,023,NN,023,Tone->Tone,NFM,5.00,,50W,,,,,
    2,SPLIT,145.500000,split,144.900000,,88.5,88.5,023,NN,023,Tone->Tone,FM,5.00,,50W,,,,,
    3,DCS,446.000000,,0.000000,DTCS,88.5,88.5,023,NN,023,Tone->Tone,NFM,12.50,,5W,,,,,
    """

    // MARK: Format detection + mapping

    @Test func usFormat() throws {
        let p = try RepeaterCSV.parse(Self.us)
        #expect(p.format == .repeaterBookUS)
        #expect(p.entries.count == 3)

        let a = p.entries[0]
        #expect(a.name == "W6ABC · Mt. Wilson, Los Angeles")
        #expect(a.freq == 146.94)
        #expect(a.offset == -0.6)
        #expect(a.txTone == 100.0)
        #expect(a.rxTone == 0)
        #expect(a.notes == "Los Angeles, California, OPEN")

        // Multi-line quoted location collapses to one line; CSQ = no tone.
        let b = p.entries[1]
        #expect(b.name == "K6XYZ · Pasadena JPL")
        #expect(b.offset == 0.6)
        #expect(b.txTone == 0)

        // 123.1 snaps to the nearest CTCSS tone.
        #expect(p.entries[2].txTone == 123.0)
        #expect(p.entries[2].offset == 5.0)
    }

    @Test func worldFormat() throws {
        let p = try RepeaterCSV.parse(Self.world)
        #expect(p.format == .repeaterBookWorld)
        #expect(p.entries.count == 2)

        let a = p.entries[0]
        #expect(a.name == "GB3XX · London")
        #expect(a.offset == -0.6)
        #expect(a.txTone == 88.5)
        #expect(a.rxTone == 88.5)  // Downlink Tone
        #expect(a.notes == "Greater London, England")

        let b = p.entries[1]
        #expect(b.name == "DB0ABC · Berlin \"Mitte\"")
        #expect(b.offset == 1.6)
        #expect(b.txTone == 0)
    }

    @Test func chirpFormat() throws {
        let p = try RepeaterCSV.parse(Self.chirp)
        #expect(p.format == .chirp)
        #expect(!p.format.isRepeaterBook)
        #expect(p.entries.count == 4)

        let tone = p.entries[0]
        #expect(tone.name == "W6ABC")
        #expect(tone.offset == -0.6)
        #expect(tone.txTone == 100.0 && tone.rxTone == 0)
        #expect(!tone.narrow)
        #expect(tone.notes == "Mt Wilson")

        let tsql = p.entries[1]
        #expect(tsql.offset == 0.6)
        #expect(tsql.txTone == 131.8 && tsql.rxTone == 131.8)
        #expect(tsql.narrow)

        #expect(p.entries[2].offset == -0.6)  // split: Offset is the TX frequency

        let dcs = p.entries[3]
        #expect(dcs.offset == 0)
        #expect(dcs.txTone == 0 && dcs.rxTone == 0)
    }

    @Test func memoryMapping() throws {
        let entry = try RepeaterCSV.parse(Self.us).entries[0]
        let mem = entry.memory(group: "LA")
        #expect(mem.group == "LA")
        #expect(mem.freq == 146.94)
        #expect(mem.offset == -0.6)
        #expect(mem.plTone == 100.0)
        #expect(mem.isRepeater)
        #expect(mem.bandwidth == 0)

        let simplex = RepeaterCSV.Entry(name: "S", freq: 146.52, offset: 0, txTone: 0, rxTone: 0, narrow: true)
            .memory(group: "G")
        #expect(!simplex.isRepeater)
        #expect(simplex.bandwidth == 1)
    }

    // MARK: Errors + edge cases

    @Test func unknownHeaderIsRejected() {
        #expect(throws: RepeaterCSV.ParseError.unrecognized) {
            try RepeaterCSV.parse("Name,Phone\nBob,555\n")
        }
    }

    @Test func headerOnlyHasNoRepeaters() {
        #expect(throws: RepeaterCSV.ParseError.noRepeaters) {
            try RepeaterCSV.parse("Freq,Input,Offset,Tone,Location,State,County,Call,Use,Miles,Bearing,Degrees\n")
        }
    }

    @Test func rowsWithoutFrequencyAreCounted() throws {
        let csv = "Freq,Input,Offset,Tone,Location,State,County,Call\n,,,,,,,\nabc,1,2,3,x,y,z,Q\n146.52,146.52,0,,Here,CA,LA,K6S\n"
        let p = try RepeaterCSV.parse(csv)
        #expect(p.entries.count == 1)
        #expect(p.skipped == 1)  // the all-empty row is dropped, "abc" is skipped
        #expect(p.entries[0].offset == 0)
    }

    @Test func offsetColumnIsFallbackWithoutInput() throws {
        let csv = "Freq,Input,Offset,Tone,Location,State,County,Call\n146.94,,-0.600,,X,CA,LA,K6S\n"
        #expect(try RepeaterCSV.parse(csv).entries[0].offset == -0.6)
    }

    @Test func byteOrderMarkAndLatin1() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(Self.world.utf8))
        #expect(try RepeaterCSV.parse(data).format == .repeaterBookWorld)

        // "Zürich" in Windows-1252 isn't valid UTF-8.
        let latin = "Output Freq,Input Freq,Offset,Uplink Tone,Downlink Tone,Call,Location\n145.6,145.0,-0.6,,,HB9X,Z\u{FC}rich\n"
        let parsed = try RepeaterCSV.parse(latin.data(using: .windowsCP1252)!)
        #expect(parsed.entries[0].name == "HB9X · Zürich")
    }

    // MARK: Tones (ToneHelper.normalizeTone parity)

    @Test func toneNormalization() {
        #expect(RepeaterCSV.normalizeTone("100.0") == 100.0)
        #expect(RepeaterCSV.normalizeTone(" 67 ") == 67.0)
        #expect(RepeaterCSV.normalizeTone("71.8") == 71.9)
        #expect(RepeaterCSV.normalizeTone("250.3") == 250.3)
        #expect(RepeaterCSV.normalizeTone("") == 0)
        #expect(RepeaterCSV.normalizeTone("0") == 0)
        #expect(RepeaterCSV.normalizeTone("1.0") == 0)
        #expect(RepeaterCSV.normalizeTone("CSQ") == 0)
        #expect(RepeaterCSV.normalizeTone("D023") == 0)
        #expect(RepeaterCSV.normalizeTone("60.0") == 0)   // > 1 Hz from 67
        #expect(RepeaterCSV.normalizeTone("300") == 0)
    }

    // MARK: Splitting

    @Test func quotedFieldsAndMultiLineRecords() {
        let records = RepeaterCSV.records("a,\"b\nc\",d\r\ne,f\n")
        #expect(records == ["a,\"b\nc\",d", "e,f"])
        #expect(RepeaterCSV.fields(records[0]) == ["a", "b c", "d"])
        #expect(RepeaterCSV.fields("\"x, y\", \"say \"\"hi\"\"\" ,") == ["x, y", "say \"hi\"", ""])
    }
}
