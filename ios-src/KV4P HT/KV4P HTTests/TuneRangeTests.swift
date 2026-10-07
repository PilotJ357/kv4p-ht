import Testing
@testable import KV4P_HT

// RadioStore.sendRadioState refuses tunes the module can't reach: the SA818
// rejects them and firmware would retry the group command forever.
struct TuneRangeTests {

    @Test func inRangeIsAllowed() {
        #expect(RadioStore.tuneRejection(rx: 146.52, tx: 146.52, min: 134, max: 174) == nil)
        #expect(RadioStore.tuneRejection(rx: 134.0, tx: 174.0, min: 134, max: 174) == nil)
    }

    @Test func vhfMemoryOnUhfModuleIsRefused() {
        #expect(RadioStore.tuneRejection(rx: 144.39, tx: 144.39, min: 400, max: 480)
                == "144.390 MHz is outside this radio's 400–480 MHz range.")
    }

    @Test func offsetPastBandEdgeIsRefused() {
        #expect(RadioStore.tuneRejection(rx: 173.9, tx: 174.5, min: 134, max: 174)
                == "Transmit frequency 174.500 MHz is outside this radio's 134–174 MHz range.")
    }

    @Test func beforeHelloEverythingPasses() {
        // RadioModuleController reports 0…999 until HELLO.
        #expect(RadioStore.tuneRejection(rx: 446.0, tx: 446.0, min: 0, max: 999) == nil)
    }
}
