import Foundation

// Debounces the firmware squelch flag for captions. The firmware soft
// squelch only holds 250 ms after the signal drops, so a weak or fading
// carrier can flick DEVICE_STATE_SQUELCHED mid-sentence. Ending the
// recognition segment on every flicker splits sentences and loses audio,
// so the gate only reports "closed" once squelch has stayed shut for
// `hangTime`. Clock-free: the caller schedules the close check.
nonisolated struct SquelchHangGate {
    enum Action: Equatable {
        case none
        // Squelch opened from closed: start captions.
        case open
        // Squelch closed while open: call closeTimerFired(now:) after this
        // many seconds.
        case scheduleClose(after: TimeInterval)
        // Squelch reopened inside the hang time: cancel the pending close.
        case cancelClose
    }

    let hangTime: TimeInterval
    private(set) var isOpen = false
    private(set) var closeDeadline: Date?
    // Closures absorbed by the hang time; diagnostic only.
    private(set) var absorbedFlaps = 0

    init(hangTime: TimeInterval) {
        self.hangTime = hangTime
    }

    var isHanging: Bool { closeDeadline != nil }

    mutating func update(squelched: Bool, now: Date) -> Action {
        if squelched {
            guard isOpen, closeDeadline == nil else { return .none }
            closeDeadline = now.addingTimeInterval(hangTime)
            return .scheduleClose(after: hangTime)
        }
        if closeDeadline != nil {
            closeDeadline = nil
            absorbedFlaps += 1
            return .cancelClose
        }
        guard !isOpen else { return .none }
        isOpen = true
        return .open
    }

    // Returns true when the gate actually closed. A timer that fires after
    // the close was cancelled (or early) is ignored.
    mutating func closeTimerFired(now: Date) -> Bool {
        guard let deadline = closeDeadline, now >= deadline else { return false }
        closeDeadline = nil
        isOpen = false
        return true
    }

    // Forget any open/hang state (captions stopped for another reason).
    mutating func reset() {
        isOpen = false
        closeDeadline = nil
    }
}

// How soon to start a new recognition segment after the current one ended
// on its own while the signal may still be present.
nonisolated enum CaptionRestartPolicy {
    enum Ending: Equatable {
        // Recognizer emitted isFinal (e.g. after a pause in speech).
        case finished
        // Recognizer reported an error.
        case failed
        // startSegment() refused (not authorized, model not ready).
        case startFailed
    }

    static func delay(after ending: Ending, retryDelay: Duration) -> Duration {
        switch ending {
        // A normal finish is not a failure: any wait drops live audio.
        case .finished: return .zero
        // Back off so a persistent failure can't spin.
        case .failed, .startFailed: return retryDelay
        }
    }
}
