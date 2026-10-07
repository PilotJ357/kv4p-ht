import Foundation

// Decides which radio settings the UI should take from the controller's
// desired state. Only values that changed since the last hydration are
// returned, so a status frame repeating an old value can't overwrite a
// control the user is moving or has just set.
//
// History: the UI used to copy the firmware's *applied* state on every
// DeviceState frame. Applied lags a user change until firmware echoes it, so
// frames in between snapped the squelch slider back (new → old → new), and
// mid-drag it fought the finger. Sending only on drag end (June) didn't touch
// that path. Desired state already follows newer firmware state (another
// host's change, or the seed on connect), so changes in it are the only
// thing the UI needs to follow.
nonisolated struct RadioSettingsHydrator {
    struct Update: Equatable {
        var squelch: UInt8?
        var bandwidth: UInt8?          // DRA818_25K / DRA818_12K5
        var highPower: Bool?
        // Firmware DSP stop filters (see RadioModuleController.setFilters):
        // FILTER_LOW is the high-pass, FILTER_HIGH the low-pass.
        var filterHighPass: Bool?
        var filterLowPass: Bool?
    }

    private var last: HostDesiredState?

    /// Settings in `desired` that differ from the previous call. `force`
    /// returns every setting (new connection: the UI adopts the radio's).
    mutating func update(from desired: HostDesiredState, force: Bool = false) -> Update {
        let prev = force ? nil : last
        last = desired
        func changed<T: Equatable>(_ value: (HostDesiredState) -> T) -> T? {
            let now = value(desired)
            return prev.map(value) == now ? nil : now
        }
        return Update(
            squelch: changed { $0.squelch },
            bandwidth: changed { $0.bw },
            highPower: changed { $0.flags & HOST_STATE_HIGH_POWER != 0 },
            filterHighPass: changed { $0.flags & HOST_STATE_FILTER_LOW != 0 },
            filterLowPass: changed { $0.flags & HOST_STATE_FILTER_HIGH != 0 })
    }
}
