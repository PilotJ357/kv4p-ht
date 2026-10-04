import Testing
import Foundation
@testable import KV4P_HT

// Collects raw DemoRadio frames; touched only on the demo's queue.
private final class FrameSink: @unchecked Sendable {
    var frames: [Data] = []
}

// Demo traffic must stay out of the real APRS history (#62).
@MainActor
struct DemoSessionTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-" + UUID().uuidString)!
    }

    private func frameBytes(from: String, payload: String) -> Data {
        AX25Frame(destination: AX25Callsign(base: "APRS", ssid: 0),
                  source: AX25Callsign(parsing: from)!,
                  digipeaters: [], payload: Data(payload.utf8))
            .encodedWithoutFCS()
    }

    private func isDemoCall(_ call: String) -> Bool {
        DemoRadio.stationCallsigns.contains(NotifyGate.baseCallsign(call))
    }

    @Test func demoSessionLeavesRealHistoryUntouched() async {
        // Stands in for the on-disk store.
        let persistence = APRSPersistence(inMemory: true)
        let defaults = freshDefaults()
        defaults.set(1234, forKey: "aprsMessageNumber")
        let aprs = APRSController(persistence: persistence, defaults: defaults)
        aprs.handleAx25Frame(frameBytes(from: "N0CALL-9", payload: "!3449.94N/08448.56W-real station"))
        let realIDs = aprs.entries.map(\.id)
        #expect(realIDs.count == 1)

        aprs.beginDemoSession()
        #expect(aprs.isDemoSession)
        #expect(aprs.entries.isEmpty)

        // Run the simulated radio: its opening bulletin plus the ack and
        // reply to a message we "send" to a demo station.
        let queue = DispatchQueue(label: "demo-session-tests")
        let demo = DemoRadio(queue: queue, center: DemoRadio.defaultCenter)
        demo.replyDelays = (0.05, 0.1)
        let sink = FrameSink()
        demo.onAx25Frame = { sink.frames.append($0) }
        let out = AX25Frame(source: AX25Callsign(base: "KC4ABC", ssid: 7), payload: Data(
            messagePayload(to: "DEMO2-7", text: "hello", msgNum: "42").utf8))
        queue.sync {
            demo.start()
            demo.receiveAx25(out.encodedWithoutFCS())
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, queue.sync(execute: { sink.frames.count < 3 }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        queue.sync { demo.stop() }
        let demoFrames = queue.sync { sink.frames }
        #expect(demoFrames.count >= 3)

        // Delivered on main, as BLEManager → RadioStore does.
        demoFrames.forEach(aprs.handleAx25Frame)
        #expect(aprs.entries.contains { $0.fromCallsign == "DEMO" && $0.kind == .bulletin })
        #expect(aprs.entries.contains { $0.fromCallsign == "DEMO2-7" && $0.text == DemoRadio.replyText })
        // Nothing reached the real store while the demo ran.
        #expect(persistence.frameSources() == ["N0CALL-9"])

        aprs.endDemoSession()
        #expect(!aprs.isDemoSession)
        #expect(aprs.entries.map(\.id) == realIDs)
        #expect(!aprs.entries.contains { isDemoCall($0.fromCallsign) || isDemoCall($0.toCallsign) })
        #expect(persistence.loadEntries(max: 100).map(\.id) == realIDs)
        #expect(!persistence.frameSources().contains(where: isDemoCall))
        #expect(persistence.frameSources() == ["N0CALL-9"])
        #expect(defaults.integer(forKey: "aprsMessageNumber") == 1234)

        // Relaunch on the same store sees only the real history.
        let relaunched = APRSController(persistence: persistence, defaults: defaults)
        #expect(relaunched.entries.map(\.id) == realIDs)
    }

    // Older builds persisted demo traffic; launch cleanup removes it and
    // leaves real traffic alone.
    @Test func launchPurgesPersistedDemoTraffic() {
        let persistence = APRSPersistence(inMemory: true)
        let now = Date()
        func entry(from: String, to: String, kind: APRSPacketKind, text: String,
                   msgNum: String? = nil, outgoing: Bool = false) -> APRSEntry {
            var e = APRSEntry(fromCallsign: from, toCallsign: to, kind: kind,
                              text: text, timestamp: now, msgNum: msgNum)
            e.isOutgoing = outgoing
            return e
        }
        func frame(_ direction: String, from: String, payload: String, kind: String?,
                   msgNum: String? = nil) {
            let raw = frameBytes(from: from, payload: payload)
            persistence.insertFrame(
                direction: direction, raw: raw, frameHash: APRSPersistence.frameHash(of: raw),
                source: from, destination: "APRS", payload: Data(payload.utf8),
                kind: kind, msgNum: msgNum, timestamp: now)
        }

        let realPosition = entry(from: "N0CALL-9", to: "APRS", kind: .position, text: "real")
        let realMessage = entry(from: "KC4ABC", to: "W1AW", kind: .message, text: "hi",
                                msgNum: "5", outgoing: true)
        for e in [
            realPosition, realMessage,
            entry(from: "DEMO1-9", to: "APRS", kind: .position, text: "Demo mobile"),
            entry(from: "DEMO", to: "BLN1", kind: .bulletin, text: "Demo mode"),
            entry(from: "KC4ABC", to: "DEMO2-7", kind: .message, text: "hello",
                  msgNum: "6", outgoing: true),
            // Canned reply sent as a non-DEMO callsign the user messaged.
            entry(from: "W1AW", to: "KC4ABC", kind: .message, text: DemoRadio.replyText,
                  msgNum: "D1234"),
        ] { persistence.insertEntry(e, frameHash: nil) }

        frame("in", from: "N0CALL-9", payload: "!3449.94N/08448.56W-real", kind: "position")
        frame("out", from: "KC4ABC", payload: ":W1AW     :hi{5", kind: "message", msgNum: "5")
        frame("in", from: "DEMOWX", payload: "!3720.09N/12200.54W_wx", kind: "position")
        frame("out", from: "KC4ABC", payload: ":DEMO3    :hi{7", kind: "message", msgNum: "7")
        frame("out", from: "KC4ABC", payload: ":DEMO3    :ackD1111", kind: "ack")
        frame("in", from: "W1AW", payload: ":KC4ABC   :\(DemoRadio.replyText){D1234",
              kind: "message", msgNum: "D1234")

        let aprs = APRSController(persistence: persistence, defaults: freshDefaults())
        #expect(Set(aprs.entries.map(\.id)) == [realPosition.id, realMessage.id])
        #expect(persistence.frameSources().sorted() == ["KC4ABC", "N0CALL-9"])
    }
}
