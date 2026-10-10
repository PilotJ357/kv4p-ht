import Foundation
import Testing
@testable import KV4P_HT

struct APRSDigipeaterTests {
    private let me = AX25Callsign(base: "KC4ABC", ssid: 7)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func frame(from: String = "N0CALL-9", path: [String],
                       payload: String = "!3500.00N/08000.00W>test") -> AX25Frame {
        AX25Frame(destination: AX25Callsign(base: "APRS", ssid: 0),
                  source: AX25Callsign(parsing: from)!,
                  digipeaters: path.map { AX25Callsign(parsing: $0)! },
                  payload: Data(payload.utf8))
    }

    private func pathText(_ f: AX25Frame?) -> [String]? {
        f?.digipeaters.map { $0.display + ($0.hasBeenRepeated ? "*" : "") }
    }

    // MARK: - Path rewrite / eligibility

    @Test func wide1FillInReplacesHopWithOurCall() {
        let out = APRSDigipeater.rewrite(frame(path: ["WIDE1-1", "WIDE2-1"]), myCall: me)
        #expect(pathText(out) == ["KC4ABC-7*", "WIDE2-1"])
    }

    @Test func rewriteKeepsSourceDestinationAndPayload() {
        let input = frame(path: ["WIDE1-1"])
        let out = APRSDigipeater.rewrite(input, myCall: me)
        #expect(out?.source == input.source)
        #expect(out?.destination == input.destination)
        #expect(out?.payload == input.payload)
    }

    @Test func explicitlyRoutedThroughUsIsMarkedUsed() {
        let out = APRSDigipeater.rewrite(frame(path: ["KC4ABC-7", "WIDE2-1"]), myCall: me)
        #expect(pathText(out) == ["KC4ABC-7*", "WIDE2-1"])
    }

    @Test func onlyFirstUnusedHopCounts() {
        // WIDE1 already used upstream; next hop is WIDE2-1 → not ours.
        #expect(APRSDigipeater.rewrite(frame(path: ["DIGI1*", "WIDE2-1"]), myCall: me) == nil)
        // Our call after an unused WIDE2-1 isn't the next hop.
        #expect(APRSDigipeater.rewrite(frame(path: ["WIDE2-2", "KC4ABC-7"]), myCall: me) == nil)
        // Used hops are skipped to reach WIDE1-1.
        let out = APRSDigipeater.rewrite(frame(path: ["DIGI1*", "WIDE1-1"]), myCall: me)
        #expect(pathText(out) == ["DIGI1*", "KC4ABC-7*"])
    }

    @Test func otherAliasesAreIgnored() {
        for hop in ["WIDE2-1", "WIDE2-2", "WIDE1-2", "WIDE1", "RELAY", "TRACE1-1", "KC4ABC", "KC4ABC-8"] {
            #expect(APRSDigipeater.rewrite(frame(path: [hop]), myCall: me) == nil, "\(hop)")
        }
    }

    @Test func fullyUsedOrEmptyPathIgnored() {
        #expect(APRSDigipeater.rewrite(frame(path: []), myCall: me) == nil)
        #expect(APRSDigipeater.rewrite(frame(path: ["DIGI1*", "DIGI2*"]), myCall: me) == nil)
    }

    @Test func ownPacketsNeverDigipeated() {
        #expect(APRSDigipeater.rewrite(frame(from: "KC4ABC-7", path: ["WIDE1-1"]), myCall: me) == nil)
        // A different SSID of the same base is another station: repeatable.
        #expect(APRSDigipeater.rewrite(frame(from: "KC4ABC-9", path: ["WIDE1-1"]), myCall: me) != nil)
    }

    @Test func packetWeAlreadyRepeatedIsNotLooped() {
        #expect(APRSDigipeater.rewrite(frame(path: ["KC4ABC-7*", "WIDE1-1"]), myCall: me) == nil)
    }

    @Test func emptyPayloadIgnored() {
        #expect(APRSDigipeater.rewrite(frame(path: ["WIDE1-1"], payload: ""), myCall: me) == nil)
    }

    @Test func rewrittenFrameEncodesRepeatedBit() {
        let out = APRSDigipeater.rewrite(frame(path: ["WIDE1-1", "WIDE2-1"]), myCall: me)!
        let decoded = AX25Frame(decoding: out.encodedWithoutFCS())
        #expect(pathText(decoded) == ["KC4ABC-7*", "WIDE2-1"])
    }

    // MARK: - Dedupe / queue

    @Test func dedupeKeyIgnoresPath() {
        #expect(APRSDigipeater.dedupeKey(of: frame(path: ["WIDE1-1", "WIDE2-1"]))
                == APRSDigipeater.dedupeKey(of: frame(path: ["DIGI1*", "WIDE2-1"])))
        #expect(APRSDigipeater.dedupeKey(of: frame(path: ["WIDE1-1"]))
                != APRSDigipeater.dedupeKey(of: frame(path: ["WIDE1-1"], payload: ">other")))
    }

    @Test func queuesAndSendsOnceChannelClear() {
        var d = APRSDigipeater()
        let queued = d.receive(frame(path: ["WIDE1-1", "WIDE2-1"]), myCall: me, frequency: 144.39, now: t0)
        #expect(queued)
        let whileBusy = d.next(now: t0.addingTimeInterval(0.5), channelClear: false)
        #expect(whileBusy == nil)
        #expect(d.pending.count == 1)
        let item = d.next(now: t0.addingTimeInterval(1), channelClear: true)
        #expect(pathText(item?.frame) == ["KC4ABC-7*", "WIDE2-1"])
        #expect(item?.frequency == 144.39)
        #expect(d.pending.isEmpty)
    }

    @Test func samePacketNotDigipeatedTwiceWithinWindow() {
        var d = APRSDigipeater()
        let f = frame(path: ["WIDE1-1", "WIDE2-1"])
        let queued = d.receive(f, myCall: me, frequency: 144.39, now: t0)
        #expect(queued)
        _ = d.next(now: t0, channelClear: true)
        // Sender retry / another copy a few seconds later.
        let retry = d.receive(f, myCall: me, frequency: 144.39, now: t0.addingTimeInterval(5))
        #expect(!retry)
        let lateCopy = d.receive(f, myCall: me, frequency: 144.39,
                                 now: t0.addingTimeInterval(APRSDigipeater.dedupeWindow - 1))
        #expect(!lateCopy)
        // After the window it's a new packet.
        let afterWindow = d.receive(f, myCall: me, frequency: 144.39,
                                    now: t0.addingTimeInterval(APRSDigipeater.dedupeWindow + 1))
        #expect(afterWindow)
    }

    @Test func copyHeardWhileWaitingCancelsOurs() {
        var d = APRSDigipeater()
        let queued = d.receive(frame(path: ["WIDE1-1", "WIDE2-1"]), myCall: me, frequency: 144.39, now: t0)
        #expect(queued)
        // A wide digi repeated it while squelch was open.
        let otherDigiCopy = d.receive(frame(path: ["DIGI1*", "WIDE2-1"]), myCall: me,
                                      frequency: 144.39, now: t0.addingTimeInterval(1))
        #expect(!otherDigiCopy)
        #expect(d.pending.isEmpty)
        let sent = d.next(now: t0.addingTimeInterval(2), channelClear: true)
        #expect(sent == nil)
        // And the original isn't re-queued by a later copy.
        let requeued = d.receive(frame(path: ["WIDE1-1", "WIDE2-1"]), myCall: me,
                                 frequency: 144.39, now: t0.addingTimeInterval(3))
        #expect(!requeued)
    }

    @Test func staleDigipeatDropped() {
        var d = APRSDigipeater()
        d.receive(frame(path: ["WIDE1-1"]), myCall: me, frequency: 144.39, now: t0)
        let sent = d.next(now: t0.addingTimeInterval(APRSDigipeater.maxHold), channelClear: true)
        #expect(sent == nil)
        #expect(d.pending.isEmpty)
    }

    @Test func queueBoundedToFirmwareDepth() {
        var d = APRSDigipeater()
        for i in 0..<(APRSDigipeater.maxPending + 2) {
            d.receive(frame(path: ["WIDE1-1"], payload: ">status \(i)"),
                      myCall: me, frequency: 144.39, now: t0)
        }
        #expect(d.pending.count == APRSDigipeater.maxPending)
        // One per tick, FIFO.
        let first = d.next(now: t0, channelClear: true)
        #expect(first?.frame.payload == Data(">status 0".utf8))
        #expect(d.pending.count == APRSDigipeater.maxPending - 1)
    }

    @Test func ineligibleFramesDontPoisonDedupe() {
        var d = APRSDigipeater()
        let wide2 = d.receive(frame(path: ["WIDE2-1"]), myCall: me, frequency: 144.39, now: t0)
        #expect(!wide2)
        let wide1 = d.receive(frame(path: ["WIDE1-1"]), myCall: me, frequency: 144.39, now: t0)
        #expect(wide1)
    }

    @Test func resetClearsQueueAndDedupe() {
        var d = APRSDigipeater()
        let f = frame(path: ["WIDE1-1"])
        d.receive(f, myCall: me, frequency: 144.39, now: t0)
        d.reset()
        #expect(d.pending.isEmpty)
        let queued = d.receive(f, myCall: me, frequency: 144.39, now: t0)
        #expect(queued)
    }

    // MARK: - Channel gate

    @Test func waitsWhileSquelchOpen() {
        #expect(!APRSDigipeater.isChannelClear(squelchLevel: 3, squelched: false))
        #expect(APRSDigipeater.isChannelClear(squelchLevel: 3, squelched: true))
    }

    @Test func squelchOffDefersToFirmwareCarrierSense() {
        #expect(APRSDigipeater.isChannelClear(squelchLevel: 0, squelched: false))
    }
}
