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
        #expect(mem.scanEnabled)
    }

    @Test func bandwidthRoundTrips() throws {
        let mem = Memory(name: "N", group: "G", freq: 446.0, offset: 0, plTone: 0,
                         squelch: 2, isRepeater: false, bandwidth: 1)
        let decoded = try JSONDecoder().decode(Memory.self, from: JSONEncoder().encode(mem))
        #expect(decoded.bandwidth == 1)
    }
}
