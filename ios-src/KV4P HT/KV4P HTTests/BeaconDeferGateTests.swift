import Testing
@testable import KV4P_HT

struct BeaconDeferGateTests {
    @Test func interruptOnAlwaysSends() {
        var g = BeaconDeferGate()
        #expect(g.evaluate(.interval, interruptReception: true, squelched: false) == .send)
        #expect(g.evaluate(.interval, interruptReception: true, squelched: true) == .send)
        #expect(!g.pending)
    }

    @Test func interruptOffSendsWhenQuiet() {
        var g = BeaconDeferGate()
        #expect(g.evaluate(.interval, interruptReception: false, squelched: true) == .send)
        #expect(!g.pending)
    }

    @Test func interruptOffHoldsWhileReceiving() {
        var g = BeaconDeferGate()
        #expect(g.evaluate(.interval, interruptReception: false, squelched: false) == .hold)
        #expect(g.pending)
        // Still receiving: keep holding.
        #expect(g.evaluate(.retry, interruptReception: false, squelched: false) == .hold)
        #expect(g.pending)
        // Squelch closed: the held beacon goes out once.
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .send)
        #expect(!g.pending)
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .skip)
    }

    // A long broadcast spanning several intervals still yields one beacon.
    @Test func intervalWhilePendingDoesNotStack() {
        var g = BeaconDeferGate()
        #expect(g.evaluate(.interval, interruptReception: false, squelched: false) == .hold)
        #expect(g.evaluate(.interval, interruptReception: false, squelched: false) == .skip)
        #expect(g.evaluate(.interval, interruptReception: false, squelched: true) == .skip)
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .send)
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .skip)
    }

    @Test func turningInterruptBackOnReleasesHeldBeacon() {
        var g = BeaconDeferGate()
        _ = g.evaluate(.interval, interruptReception: false, squelched: false)
        #expect(g.evaluate(.retry, interruptReception: true, squelched: false) == .send)
        #expect(!g.pending)
    }

    @Test func manualSendsWhileReceivingAndClearsPending() {
        var g = BeaconDeferGate()
        _ = g.evaluate(.interval, interruptReception: false, squelched: false)
        #expect(g.evaluate(.manual, interruptReception: false, squelched: false) == .send)
        #expect(!g.pending)
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .skip)
    }

    @Test func retryWithNothingPendingSkips() {
        var g = BeaconDeferGate()
        #expect(g.evaluate(.retry, interruptReception: false, squelched: false) == .skip)
    }

    @Test func resetDropsPending() {
        var g = BeaconDeferGate()
        _ = g.evaluate(.interval, interruptReception: false, squelched: false)
        g.reset()
        #expect(!g.pending)
        #expect(g.evaluate(.retry, interruptReception: false, squelched: true) == .skip)
    }
}
