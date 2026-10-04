import Foundation
import Testing
@testable import KV4P_HT

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

struct SquelchHangGateTests {

    @Test func opensOnFirstUnsquelch() {
        var gate = SquelchHangGate(hangTime: 1.5)
        let action = gate.update(squelched: false, now: at(0))
        #expect(action == .open)
        #expect(gate.isOpen)
        // Already open: nothing more to do.
        let action2 = gate.update(squelched: false, now: at(0.1))
        #expect(action2 == .none)
    }

    @Test func squelchedWhileClosedDoesNothing() {
        var gate = SquelchHangGate(hangTime: 1.5)
        let action = gate.update(squelched: true, now: at(0))
        #expect(action == .none)
        #expect(!gate.isOpen)
        #expect(!gate.isHanging)
    }

    @Test func closeWaitsForHangTime() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        let action = gate.update(squelched: true, now: at(2))
        #expect(action == .scheduleClose(after: 1.5))
        #expect(gate.isOpen)
        #expect(gate.isHanging)
        // Early fire is ignored.
        let closed = gate.closeTimerFired(now: at(3))
        #expect(!closed)
        #expect(gate.isOpen)
        let closed2 = gate.closeTimerFired(now: at(3.5))
        #expect(closed2)
        #expect(!gate.isOpen)
        #expect(!gate.isHanging)
    }

    // The reported bug: soft squelch flicks closed mid-sentence. A reopen
    // inside the hang time must keep the segment alive.
    @Test func flickerInsideHangTimeIsAbsorbed() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        let action = gate.update(squelched: true, now: at(1))
        #expect(action == .scheduleClose(after: 1.5))
        let action2 = gate.update(squelched: false, now: at(1.3))
        #expect(action2 == .cancelClose)
        #expect(gate.isOpen)
        #expect(gate.absorbedFlaps == 1)
        // The stale timer from the cancelled close must not close the gate.
        let closed = gate.closeTimerFired(now: at(2.5))
        #expect(!closed)
        #expect(gate.isOpen)
    }

    @Test func repeatedSquelchedDoesNotExtendDeadline() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        _ = gate.update(squelched: true, now: at(1))
        let action = gate.update(squelched: true, now: at(2))
        #expect(action == .none)
        #expect(gate.closeDeadline == at(2.5))
    }

    @Test func newCloseAfterFlickerGetsFreshHang() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        _ = gate.update(squelched: true, now: at(1))
        _ = gate.update(squelched: false, now: at(1.2))
        let action = gate.update(squelched: true, now: at(5))
        #expect(action == .scheduleClose(after: 1.5))
        let closed = gate.closeTimerFired(now: at(6))
        #expect(!closed)
        let closed2 = gate.closeTimerFired(now: at(6.5))
        #expect(closed2)
    }

    @Test func reopensAfterFullClose() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        _ = gate.update(squelched: true, now: at(1))
        _ = gate.closeTimerFired(now: at(2.5))
        let action = gate.update(squelched: false, now: at(3))
        #expect(action == .open)
    }

    @Test func resetClearsHang() {
        var gate = SquelchHangGate(hangTime: 1.5)
        _ = gate.update(squelched: false, now: at(0))
        _ = gate.update(squelched: true, now: at(1))
        gate.reset()
        #expect(!gate.isOpen)
        #expect(!gate.isHanging)
        let closed = gate.closeTimerFired(now: at(10))
        #expect(!closed)
        let action = gate.update(squelched: false, now: at(11))
        #expect(action == .open)
    }
}
