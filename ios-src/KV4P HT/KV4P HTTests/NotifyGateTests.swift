import Foundation
import Testing
@testable import KV4P_HT

// MARK: - NotifyGate decision logic

struct NotifyGateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(kind: APRSPacketKind = .position,
                       from: String = "KJ6ABC-9",
                       to: String = "APRS",
                       text: String = "hi",
                       outgoing: Bool = false) -> APRSEntry {
        APRSEntry(fromCallsign: from, toCallsign: to, kind: kind,
                  text: text, timestamp: now, isOutgoing: outgoing)
    }

    private func ctx(addressed: Bool = false, distance: Double? = nil,
                     last: Date? = nil) -> NotifyGate.Context {
        .init(isAddressedToMe: addressed, distanceMi: distance, lastNotifiedAt: last)
    }

    private var on: APRSNotifySettings {
        var s = APRSNotifySettings()
        s.enabled = true
        return s
    }

    @Test func disabledNeverFires() {
        var s = on; s.enabled = false
        #expect(!NotifyGate.shouldFire(entry(), settings: s, context: ctx(), now: now))
    }

    @Test func outgoingNeverFires() {
        #expect(!NotifyGate.shouldFire(entry(outgoing: true), settings: on,
                                       context: ctx(), now: now))
    }

    @Test func disabledKindSuppressed() {
        var s = on; s.perKind[APRSPacketKind.position.rawValue] = false
        #expect(!NotifyGate.shouldFire(entry(kind: .position), settings: s,
                                       context: ctx(), now: now))
    }

    @Test func mutedStationSuppressed() {
        var s = on; s.mutedCallsigns = ["KJ6ABC"]  // base, no SSID
        #expect(!NotifyGate.shouldFire(entry(from: "KJ6ABC-9"), settings: s,
                                       context: ctx(), now: now))
    }

    @Test func onlyMessagesToMe() {
        var s = on; s.onlyMessagesToMe = true
        let m = entry(kind: .message, to: "ME")
        #expect(!NotifyGate.shouldFire(m, settings: s, context: ctx(addressed: false), now: now))
        #expect(NotifyGate.shouldFire(m, settings: s, context: ctx(addressed: true), now: now))
    }

    @Test func distanceFilter() {
        var s = on; s.distanceFilterMi = 25
        #expect(!NotifyGate.shouldFire(entry(), settings: s, context: ctx(distance: 40), now: now))
        #expect(NotifyGate.shouldFire(entry(), settings: s, context: ctx(distance: 10), now: now))
        // No position ⇒ can't filter ⇒ allowed.
        #expect(NotifyGate.shouldFire(entry(), settings: s, context: ctx(distance: nil), now: now))
    }

    @Test func beaconCooldownThrottles() {
        let recent = now.addingTimeInterval(-60)   // < 300s default cooldown
        #expect(!NotifyGate.shouldFire(entry(kind: .position), settings: on,
                                       context: ctx(last: recent), now: now))
        let old = now.addingTimeInterval(-600)      // > cooldown
        #expect(NotifyGate.shouldFire(entry(kind: .position), settings: on,
                                      context: ctx(last: old), now: now))
    }

    @Test func messageToMeBypassesCooldown() {
        let recent = now.addingTimeInterval(-1)
        let m = entry(kind: .message, to: "ME")
        #expect(NotifyGate.shouldFire(m, settings: on,
                                      context: ctx(addressed: true, last: recent), now: now))
    }
}
