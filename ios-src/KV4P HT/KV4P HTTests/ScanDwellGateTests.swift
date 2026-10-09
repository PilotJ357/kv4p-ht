import Foundation
import Testing
@testable import KV4P_HT

private let t0 = Date(timeIntervalSinceReferenceDate: 0)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

struct ScanDwellGateTests {

    private func tunedGate() -> ScanDwellGate {
        var gate = ScanDwellGate()
        gate.tuned(to: 146.52, now: at(0))
        return gate
    }

    @Test func waitsForTuneToLandBeforeDwelling() {
        var gate = tunedGate()
        // Radio still on the previous channel, squelched: no advance.
        #expect(gate.update(appliedRxFreq: 146.94, active: false, now: at(0.3)) == .wait)
        #expect(gate.update(appliedRxFreq: 146.94, active: false, now: at(0.9)) == .wait)
        // Confirmed at 1.0: dwell runs from there.
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(1.0)) == .wait)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(1.4)) == .wait)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(1.5)) == .advance)
    }

    // #125: squelch can't open within 250 ms of a retune, so a channel
    // with a carrier must still be there when it does.
    @Test func holdsWhenSquelchOpensWithinDwell() {
        var gate = tunedGate()
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(0.1)) == .wait)
        #expect(gate.update(appliedRxFreq: 146.52, active: true, now: at(0.45)) == .hold)
        #expect(gate.isHolding)
        #expect(gate.update(appliedRxFreq: 146.52, active: true, now: at(5)) == .hold)
    }

    @Test func resumesAfterQuietForResumeDelay() {
        var gate = tunedGate()
        _ = gate.update(appliedRxFreq: 146.52, active: false, now: at(0.1))
        _ = gate.update(appliedRxFreq: 146.52, active: true, now: at(0.5))
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(1.0)) == .hold)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(2.4)) == .hold)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(2.5)) == .advance)
    }

    @Test func reopenRestartsResumeDelay() {
        var gate = tunedGate()
        _ = gate.update(appliedRxFreq: 146.52, active: false, now: at(0.1))
        _ = gate.update(appliedRxFreq: 146.52, active: true, now: at(0.5))
        _ = gate.update(appliedRxFreq: 146.52, active: false, now: at(1.0))
        #expect(gate.update(appliedRxFreq: 146.52, active: true, now: at(2.0)) == .hold)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(3.9)) == .hold)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(4.0)) == .advance)
    }

    // The reconcile frame can carry the previous channel's open squelch.
    @Test func ignoresOpenFlagRightAfterConfirm() {
        var gate = tunedGate()
        #expect(gate.update(appliedRxFreq: 146.52, active: true, now: at(0.1)) == .wait)
        #expect(!gate.isHolding)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(0.6)) == .advance)
    }

    @Test func advancesWhenTuneNeverConfirms() {
        var gate = tunedGate()
        #expect(gate.update(appliedRxFreq: nil, active: false, now: at(1.9)) == .wait)
        #expect(gate.update(appliedRxFreq: nil, active: false, now: at(2.0)) == .advance)
    }

    @Test func retuneClearsHold() {
        var gate = tunedGate()
        _ = gate.update(appliedRxFreq: 146.52, active: false, now: at(0.1))
        _ = gate.update(appliedRxFreq: 146.52, active: true, now: at(0.5))
        gate.tuned(to: 147.0, now: at(3))
        #expect(!gate.isHolding)
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(3.6)) == .wait)
    }

    @Test func idleGateNeverAdvances() {
        var gate = ScanDwellGate()
        #expect(gate.update(appliedRxFreq: 146.52, active: false, now: at(100)) == .wait)
    }
}
