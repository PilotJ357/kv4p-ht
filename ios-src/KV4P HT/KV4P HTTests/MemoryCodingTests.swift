import Foundation
import Testing
@testable import KV4P_HT

struct MemoryCodingTests {
    @Test func legacyMemoryDecodesAsWide() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Rptr","group":"Local","freq":146.94,
         "offset":-0.6,"plTone":100,"squelch":2,"isRepeater":true}
        """
        let mem = try JSONDecoder().decode(Memory.self, from: Data(json.utf8))
        #expect(mem.bandwidth == 0)
        #expect(mem.rxTone == 0)
        #expect(mem.scanEnabled)
        #expect(!mem.aprsRegionLinked)
        #expect(!mem.freeDv2400b)
    }

    @Test func voiceModeRoundTripsAndShowsInMeta() throws {
        let mem = Memory(name: "DV", group: "G", freq: 146.55, offset: 0, plTone: 0,
                         squelch: 2, isRepeater: false, freeDv2400b: true)
        let decoded = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(mem))
        #expect(decoded.freeDv2400b)
        #expect(decoded.metaString.hasSuffix("· 2400B"))
    }

    @Test func aprsRegionLinkRoundTrips() throws {
        let mem = Memory(name: "APRS (US)", group: "APRS", freq: 144.39, offset: 0, plTone: 0,
                         squelch: 2, isRepeater: false, aprsRegionLinked: true)
        let decoded = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(mem))
        #expect(decoded.aprsRegionLinked)
    }

    @Test func aprsRegionLookup() {
        #expect(APRSRegion.for("144.3900")?.memoryName == "APRS (US)")
        #expect(APRSRegion.for("144.8000")?.freq == 144.8)
        #expect(APRSRegion.for("Current") == nil)
    }

    @Test func bandwidthRoundTrips() throws {
        let mem = Memory(name: "N", group: "G", freq: 446.0, offset: 0, plTone: 0,
                         squelch: 2, isRepeater: false, bandwidth: 1)
        let decoded = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(mem))
        #expect(decoded.bandwidth == 1)
    }

    // #124: RX tone squelch is stored per memory, like Android's rx_tone.
    @Test func rxToneRoundTrips() throws {
        let mem = Memory(name: "Rptr", group: "G", freq: 146.94, offset: -0.6, plTone: 100,
                         rxTone: 107.2, squelch: 2, isRepeater: true)
        let decoded = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(mem))
        #expect(decoded.rxTone == 107.2)
        #expect(decoded.toneString == "100.0/107.2")
    }
}

// Duplicate frequencies (e.g. an import repeating a hand-entered memory):
// the one last tuned is the active one, not just the first in the list.
struct ActiveMemoryTests {
    private func mem(_ name: String, _ freq: Float) -> Memory {
        Memory(name: name, group: "G", freq: freq, offset: 0, plTone: 0, squelch: 2, isRepeater: false)
    }

    @Test func prefersLastAppliedAmongDuplicates() {
        let a = mem("Manual", 146.94), b = mem("Imported", 146.94)
        #expect(RadioStore.memory(in: [a, b], for: 146.94, preferring: nil)?.id == a.id)
        #expect(RadioStore.memory(in: [a, b], for: 146.94, preferring: b.id)?.id == b.id)
    }

    @Test func staleOrDeletedPreferenceFallsBack() {
        let a = mem("A", 146.94), b = mem("B", 147.24)
        // Tuned elsewhere since: the remembered memory doesn't match the frequency.
        #expect(RadioStore.memory(in: [a, b], for: 146.94, preferring: b.id)?.id == a.id)
        #expect(RadioStore.memory(in: [a, b], for: 146.94, preferring: UUID())?.id == a.id)
        #expect(RadioStore.memory(in: [a, b], for: 145.0, preferring: a.id) == nil)
    }
}
