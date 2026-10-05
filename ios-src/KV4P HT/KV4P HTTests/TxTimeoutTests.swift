import Testing
@testable import KV4P_HT

struct TxTimeoutTests {

    @Test func okBeforeWarning() {
        #expect(TxTimeout.phase(elapsed: 0, limit: 180) == .ok)
        #expect(TxTimeout.phase(elapsed: 169.9, limit: 180) == .ok)
    }

    @Test func warnsInLastTenSeconds() {
        #expect(TxTimeout.phase(elapsed: 170, limit: 180) == .warning(remaining: 10))
        #expect(TxTimeout.phase(elapsed: 175.5, limit: 180) == .warning(remaining: 5))
        #expect(TxTimeout.phase(elapsed: 179.9, limit: 180) == .warning(remaining: 1))
    }

    @Test func expiresAtLimit() {
        #expect(TxTimeout.phase(elapsed: 180, limit: 180) == .expired)
        #expect(TxTimeout.phase(elapsed: 900, limit: 180) == .expired)
    }

    @Test func offNeverExpires() {
        #expect(TxTimeout.phase(elapsed: 100_000, limit: 0) == .ok)
    }

    @Test func defaultIsAnOption() {
        #expect(TxTimeout.options.contains(TxTimeout.defaultSeconds))
    }

    @Test func labels() {
        #expect(TxTimeout.label(0) == "Off")
        #expect(TxTimeout.label(180) == "3 min")
    }
}
