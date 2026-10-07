import Foundation
import Testing
@testable import KV4P_HT

private func linked(_ name: String, freq: Float) -> Memory {
    Memory(name: name, group: "APRS", freq: freq, offset: 0, plTone: 0,
           squelch: 2, isRepeater: false, aprsRegionLinked: true)
}

// #108: Japan's 1200-baud channel is 144.660 (144.640 is its 9600 channel),
// 144.640 is China, and Australia is 145.175.
struct APRSRegionTests {

    @Test func tableMatchesRegionalChannels() {
        #expect(APRSRegion.for("144.6600")?.memoryName == "APRS (JP)")
        #expect(APRSRegion.for("144.6400")?.memoryName == "APRS (CN)")
        #expect(APRSRegion.for("145.1750")?.memoryName == "APRS (AU)")
        #expect(APRSRegion.for("144.9300")?.memoryName == "APRS (AR)")
        #expect(APRSRegion.for("145.5700")?.memoryName == "APRS (BR)")
        #expect(APRSRegion.for("144.3900")?.memoryName == "APRS (US)")
    }

    @Test func settingsAreUniqueAndRoundTrip() {
        let settings = APRSRegion.all.map(\.setting)
        #expect(Set(settings).count == settings.count)
        for r in APRSRegion.all {
            #expect(String(format: "%.4f", r.freq) == r.setting)
        }
        #expect(APRSRegion.all.map(\.freq) == APRSRegion.all.map(\.freq).sorted())
    }

    @Test func freshInstallDefaultFollowsDeviceRegion() {
        #expect(APRSRegion.defaultSetting(forRegion: "JP") == "144.6600")
        #expect(APRSRegion.defaultSetting(forRegion: "CN") == "144.6400")
        #expect(APRSRegion.defaultSetting(forRegion: "AU") == "145.1750")
        #expect(APRSRegion.defaultSetting(forRegion: "NZ") == "144.5750")
        #expect(APRSRegion.defaultSetting(forRegion: "DE") == "144.8000")
        #expect(APRSRegion.defaultSetting(forRegion: "gb") == "144.8000")
        #expect(APRSRegion.defaultSetting(forRegion: "ZA") == "144.8000")
        #expect(APRSRegion.defaultSetting(forRegion: "BR") == "145.5700")
        #expect(APRSRegion.defaultSetting(forRegion: "UY") == "144.9300")
        #expect(APRSRegion.defaultSetting(forRegion: "US") == "144.3900")
        #expect(APRSRegion.defaultSetting(forRegion: nil) == "144.3900")
        for code in ["JP", "CN", "AU", "NZ", "DE", "BR", "AR", "US"] {
            #expect(APRSRegion.for(APRSRegion.defaultSetting(forRegion: code)) != nil)
        }
    }

    @Test func migrationMovesOnlyMislabeledChoices() {
        #expect(APRSRegion.migratedSetting("144.6400", region: "JP") == "144.6600")
        #expect(APRSRegion.migratedSetting("144.6600", region: "AU") == "145.1750")
        #expect(APRSRegion.migratedSetting("144.6400", region: "CN") == nil)
        #expect(APRSRegion.migratedSetting("144.6600", region: "US") == nil)
        #expect(APRSRegion.migratedSetting("144.6600", region: "JP") == nil)
        #expect(APRSRegion.migratedSetting("144.3900", region: "JP") == nil)
        #expect(APRSRegion.migratedSetting("Current", region: "AU") == nil)
        #expect(APRSRegion.migratedSetting("144.6400", region: nil) == nil)
    }

    @Test func linkedMemoryRenamesAutoNamesIncludingLegacy() throws {
        let au = try #require(APRSRegion.for("145.1750"))
        let renamed = APRSRegion.linkedMemory(linked("APRS (AU alt)", freq: 145.175), for: au)
        #expect(renamed.name == "APRS (AU)")

        let cn = try #require(APRSRegion.for("144.6400"))
        let fromOldJapan = APRSRegion.linkedMemory(linked("APRS (JP)", freq: 144.64), for: cn)
        #expect(fromOldJapan.name == "APRS (CN)")
        #expect(fromOldJapan.freq == cn.freq)
    }

    @Test func linkedMemoryKeepsUserNameButRetunes() throws {
        let jp = try #require(APRSRegion.for("144.6600"))
        let mem = APRSRegion.linkedMemory(linked("Home APRS", freq: 144.64), for: jp)
        #expect(mem.name == "Home APRS")
        #expect(mem.freq == jp.freq)
        #expect(mem.aprsRegionLinked)
    }
}
