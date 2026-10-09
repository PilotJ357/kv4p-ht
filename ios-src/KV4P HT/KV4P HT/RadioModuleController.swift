import Foundation

/// Owns the iOS-side desired/applied radio state (port of Android's
/// `RadioModuleController`).
///
/// The transport (BLEManager) only knows how to write frames; this class
/// decides what the next desired-state snapshot should contain and when one
/// must be emitted. UI writes go through the problem-oriented setters, which
/// mutate desired state and send a `HostDesiredState` frame only when
/// something actually changed. Firmware `DEVICE_STATE` frames feed
/// `updateDeviceState(_:)`, which tracks applied-state sync and retries the
/// last sent desired state (up to `maxDesiredStateRetries`) on mismatch.
///
/// TX_ALLOWED is derived here, not set by callers: every desired-state change
/// re-checks the TX frequency and bandwidth against `BandPlan` for the HELLO
/// module type and the user's TX band limits (Android calls `updateTxAllowed`
/// on each tune and from `updateTxLimitsForBand` instead).
///
/// Thread-safe: setters may be called from the main thread while transport
/// callbacks arrive on bleQueue. The injected send callback is invoked while
/// the internal lock is held, so it must not call back into this class
/// synchronously (BLEManager dispatches onto bleQueue).
nonisolated final class RadioModuleController: @unchecked Sendable {
    static let maxDesiredStateRetries = 3

    private static let desiredDeviceFlagsMask: UInt16 =
        HOST_STATE_RADIO_CONFIG_VALID
        | HOST_STATE_PTT_REQUESTED
        | HOST_STATE_RX_AUDIO_OPEN
        | HOST_STATE_HIGH_POWER
        | HOST_STATE_RSSI_ENABLED
        | HOST_STATE_FILTER_PRE
        | HOST_STATE_FILTER_HIGH
        | HOST_STATE_FILTER_LOW
        | HOST_STATE_TX_ALLOWED
        | HOST_STATE_ENABLE_STATUS_REPORTS

    private static let defaultDesiredFlags: UInt16 =
        HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED | HOST_STATE_ENABLE_STATUS_REPORTS

    private static let initialDesiredState = HostDesiredState(
        sequence: 0, memoryId: -1, flags: defaultDesiredFlags, bw: DRA818_25K,
        freqTx: 0, freqRx: 0, ctcssTx: 0, squelch: 0, ctcssRx: 0)

    private let lock = NSRecursiveLock()

    private var send: ((HostDesiredState) -> Void)?
    private var firmwareInfo: HelloFrame?
    private var _txBandLimits = TxBandLimits.defaults
    private var _desiredState = RadioModuleController.initialDesiredState
    private var updateDepth = 0
    private var lastDesiredStateSent: HostDesiredState?
    private var lastDeviceState: DeviceStateFrame?
    private var lastPhysPttDown = false
    private var _appliedStateInSync = false
    private var transportReady = false
    private var desiredStateRetries = 0

    // MARK: - Transport lifecycle

    func attachTransport(_ send: @escaping (HostDesiredState) -> Void) {
        withLock {
            self.send = send
            transportReady = false
            lastDesiredStateSent = _desiredState
            desiredStateRetries = 0
        }
    }

    func markTransportReady() {
        withLock {
            transportReady = true
            sendDesiredStateIfChanged()
        }
    }

    func detachTransport() {
        withLock {
            send = nil
            transportReady = false
            lastDesiredStateSent = nil
            lastDeviceState = nil
            firmwareInfo = nil
            _appliedStateInSync = false
            desiredStateRetries = 0
        }
    }

    // MARK: - Seeding from HELLO

    func seedFirmwareInfo(_ hello: HelloFrame) {
        withLock {
            firmwareInfo = hello
            updateDesiredState { _ in }  // module type moves the TX band
        }
    }

    func seedFromDeviceState(_ state: DeviceStateFrame) {
        withLock {
            lastDeviceState = state
            lastPhysPttDown = isPhysPttDown
            _desiredState = desiredBaseline(from: state)
            // Strip STATUS_REPORTS from the no-op baseline so the post-HELLO
            // flush always emits at least one frame that (re-)enables reports.
            lastDesiredStateSent = withFlags(_desiredState, _desiredState.flags & ~HOST_STATE_ENABLE_STATUS_REPORTS)
            _appliedStateInSync = isDeviceStateInSync(state, with: lastDesiredStateSent)
            desiredStateRetries = 0
            // Firmware persists TX_ALLOWED in NVS; re-derive it for this tune.
            applyTxPolicy(&_desiredState)
        }
    }

    // MARK: - TX band limits

    var txBandLimits: TxBandLimits {
        withLock { _txBandLimits }
    }

    /// New band edges re-derive TX_ALLOWED for the current tune right away.
    func setTxBandLimits(_ limits: TxBandLimits) {
        withLock {
            guard limits != _txBandLimits else { return }
            _txBandLimits = limits
            updateDesiredState { _ in }
        }
    }

    // MARK: - Batched updates

    func beginUpdate() {
        withLock { updateDepth += 1 }
    }

    func endUpdate() {
        withLock {
            guard updateDepth > 0 else { return }
            updateDepth -= 1
            if updateDepth == 0 {
                sendDesiredStateIfChanged()
            }
        }
    }

    // MARK: - Desired-state setters (UI writes)

    func pttDown() { setDesiredFlag(HOST_STATE_PTT_REQUESTED, true) }
    func pttUp()   { setDesiredFlag(HOST_STATE_PTT_REQUESTED, false) }

    func setBandwidth(_ bandwidth: UInt8) {
        updateRadioConfig { $0.bw = bandwidth }
    }

    func setTxFrequency(_ txFrequency: Float) {
        updateRadioConfig { $0.freqTx = txFrequency }
    }

    func setRxFrequency(_ rxFrequency: Float) {
        updateRadioConfig { $0.freqRx = rxFrequency }
    }

    func setMemoryId(_ memoryId: Int32) {
        updateRadioConfig { $0.memoryId = memoryId }
    }

    func setTxTone(_ txTone: UInt8) {
        updateRadioConfig { $0.ctcssTx = txTone }
    }

    func setRxTone(_ rxTone: UInt8) {
        updateRadioConfig { $0.ctcssRx = rxTone }
    }

    func setSquelch(_ squelch: UInt8) {
        updateRadioConfig { $0.squelch = squelch }
    }

    /// Firmware (dkaukov v2) bypasses the SA818's own HPF/LPF and runs the
    /// stop filters in DSP on the voice path: FILTER_LOW cuts below 300 Hz
    /// (high-pass), FILTER_HIGH cuts above 3 kHz (low-pass). FILTER_PRE is
    /// never sent — see `disableHardwareDeemphasis()`.
    func setFilters(highpass: Bool, lowpass: Bool) {
        withLock {
            var flags = _desiredState.flags & ~(HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW)
            if highpass { flags |= HOST_STATE_FILTER_LOW }
            if lowpass  { flags |= HOST_STATE_FILTER_HIGH }
            updateDesiredState { $0.flags = flags }
        }
    }

    /// SA818 de-emphasis strips the 3.5–4 kHz noise the firmware soft squelch
    /// keys on, so squelch never closes. Clears a FILTER_PRE persisted in
    /// firmware NVS by older app builds.
    func disableHardwareDeemphasis() {
        setDesiredFlag(HOST_STATE_FILTER_PRE, false)
    }

    func setHighPower(_ isHighPower: Bool) {
        setDesiredFlag(HOST_STATE_HIGH_POWER, isHighPower)
    }

    func setRssiEnabled(_ on: Bool) {
        setDesiredFlag(HOST_STATE_RSSI_ENABLED, on)
    }

    func openAudio() {
        withLock {
            updateDesiredState { $0.flags |= HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_ENABLE_STATUS_REPORTS }
        }
    }

    func closeAudio() {
        clearDesiredFlags(HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_PTT_REQUESTED | HOST_STATE_ENABLE_STATUS_REPORTS)
    }

    func stop() {
        clearDesiredFlags(HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_PTT_REQUESTED | HOST_STATE_ENABLE_STATUS_REPORTS)
    }

    func flushDesiredState() {
        withLock { sendDesiredStateIfChanged() }
    }

    // MARK: - Firmware device state (UI reads)

    func updateDeviceState(_ state: DeviceStateFrame) {
        withLock {
            lastPhysPttDown = isPhysPttDown
            lastDeviceState = state
            var adopted = false
            if isDeviceStateInSync(state, with: lastDesiredStateSent) {
                _appliedStateInSync = true
            } else if let lastSent = lastDesiredStateSent, state.appliedSequence > lastSent.sequence {
                _desiredState = desiredBaseline(from: state, clearingRuntimeRequests: false)
                lastDesiredStateSent = _desiredState
                _appliedStateInSync = true
                adopted = true
            } else {
                _appliedStateInSync = false
            }
            if _appliedStateInSync {
                desiredStateRetries = 0
            } else {
                retryDesiredStateIfNeeded()
            }
            // Adopted firmware flags may carry a TX_ALLOWED this tune doesn't earn.
            if adopted { updateDesiredState { _ in } }
        }
    }

    var desiredState: HostDesiredState {
        withLock { _desiredState }
    }

    var deviceState: DeviceStateFrame? {
        withLock { lastDeviceState }
    }

    var isAppliedStateInSync: Bool {
        withLock { _appliedStateInSync }
    }

    var isHighPowerEnabled: Bool { hasDesiredFlag(HOST_STATE_HIGH_POWER) }
    var isTxAllowed: Bool { hasDesiredFlag(HOST_STATE_TX_ALLOWED) }
    var desiredSquelch: UInt8 { withLock { _desiredState.squelch } }
    var desiredBandwidth: UInt8 { withLock { _desiredState.bw } }

    /// Band check for a TX frequency other than the desired one (e.g. an
    /// APRS beacon frequency) at the desired bandwidth. False before HELLO.
    func canTransmit(onFrequency freq: Float) -> Bool {
        withLock { canTransmit(onFrequency: freq, bandwidth: _desiredState.bw) }
    }

    var isPhysPttDown: Bool { hasDeviceFlag(DEVICE_STATE_PHYS_PTT_DOWN) }
    var isSquelched: Bool { hasDeviceFlag(DEVICE_STATE_SQUELCHED) }

    var didPhysPttChange: Bool {
        withLock { lastPhysPttDown != isPhysPttDown }
    }

    // MARK: - Firmware metadata (from HELLO)

    var firmwareVersion: Int {
        withLock { firmwareInfo.map { Int($0.firmwareVersion) } ?? -1 }
    }

    var minRadioFreq: Float {
        withLock { firmwareInfo?.minFreq ?? 0.0 }
    }

    var maxRadioFreq: Float {
        withLock { firmwareInfo?.maxFreq ?? 999.0 }
    }

    /// Whether the module can tune `freq` (HELLO range). True before HELLO.
    func isTunable(_ freq: Float) -> Bool {
        withLock { firmwareInfo.map { freq >= $0.minFreq && freq <= $0.maxFreq } ?? true }
    }

    var hasHighLowPowerSwitch: Bool {
        withLock { firmwareInfo.map { ($0.features & 0x01) != 0 } ?? false }
    }

    var hasPhysPttButton: Bool {
        withLock { firmwareInfo.map { ($0.features & 0x02) != 0 } ?? false }
    }

    // MARK: - Private

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withFlags(_ state: HostDesiredState, _ flags: UInt16) -> HostDesiredState {
        var next = state
        next.flags = flags
        return next
    }

    private func desiredBaseline(from state: DeviceStateFrame, clearingRuntimeRequests: Bool = true) -> HostDesiredState {
        guard state.hasRadioConfig else {
            var baseline = Self.initialDesiredState
            baseline.sequence = state.appliedSequence
            return baseline
        }
        var flags = state.flags & Self.desiredDeviceFlagsMask & ~HOST_STATE_PTT_REQUESTED
        if clearingRuntimeRequests {
            flags &= ~HOST_STATE_RX_AUDIO_OPEN
        }
        flags |= HOST_STATE_ENABLE_STATUS_REPORTS
        return HostDesiredState(
            sequence: state.appliedSequence,
            memoryId: state.memoryId,
            flags: flags,
            bw: state.bw,
            freqTx: state.freqTx,
            freqRx: state.freqRx,
            ctcssTx: state.ctcssTx,
            squelch: state.squelch,
            ctcssRx: state.ctcssRx)
    }

    private func isDeviceStateInSync(_ deviceState: DeviceStateFrame?, with desiredState: HostDesiredState?) -> Bool {
        guard let deviceState, let desiredState, deviceState.lastError == 0 else { return false }
        guard deviceState.appliedSequence == desiredState.sequence else { return false }
        return isDeviceStateContentInSync(deviceState, with: desiredState)
    }

    private func isDeviceStateContentInSync(_ deviceState: DeviceStateFrame, with desiredState: HostDesiredState) -> Bool {
        guard deviceState.lastError == 0 else { return false }
        guard (deviceState.flags & Self.desiredDeviceFlagsMask) == (desiredState.flags & Self.desiredDeviceFlagsMask) else {
            return false
        }
        guard (desiredState.flags & HOST_STATE_RADIO_CONFIG_VALID) != 0 else { return true }
        return deviceState.bw == desiredState.bw
            && deviceState.memoryId == desiredState.memoryId
            && deviceState.freqTx == desiredState.freqTx
            && deviceState.freqRx == desiredState.freqRx
            && deviceState.ctcssTx == desiredState.ctcssTx
            && deviceState.squelch == desiredState.squelch
            && deviceState.ctcssRx == desiredState.ctcssRx
    }

    private func updateRadioConfig(_ change: (inout HostDesiredState) -> Void) {
        withLock {
            updateDesiredState { state in
                let before = state
                change(&state)
                if state != before {
                    state.flags |= HOST_STATE_RADIO_CONFIG_VALID
                }
            }
        }
    }

    private func setDesiredFlag(_ flag: UInt16, _ enabled: Bool) {
        withLock {
            updateDesiredState { state in
                if enabled { state.flags |= flag } else { state.flags &= ~flag }
            }
        }
    }

    private func clearDesiredFlags(_ flags: UInt16) {
        withLock {
            updateDesiredState { $0.flags &= ~flags }
        }
    }

    private func updateDesiredState(_ change: (inout HostDesiredState) -> Void) {
        var next = _desiredState
        change(&next)
        applyTxPolicy(&next)
        if next != _desiredState {
            _desiredState = next
            sendDesiredStateIfChanged()
        }
    }

    private func isConfigTunable(_ state: HostDesiredState) -> Bool {
        (state.flags & HOST_STATE_RADIO_CONFIG_VALID) == 0
            || (isTunable(state.freqTx) && isTunable(state.freqRx))
    }

    private func canTransmit(onFrequency freq: Float, bandwidth: UInt8) -> Bool {
        guard let firmwareInfo else { return false }
        return BandPlan.canTransmit(onFrequency: freq, bandwidth: bandwidth,
                                    rfModuleType: firmwareInfo.rfModuleType,
                                    limits: _txBandLimits,
                                    moduleRange: firmwareInfo.tuneRange)
    }

    // Firmware gates PTT and AX.25 TX on TX_ALLOWED alone. Dropping it also
    // drops any PTT request, so a held/sticky PTT can't follow a tune out of
    // band and key up later when the flag returns.
    private func applyTxPolicy(_ state: inout HostDesiredState) {
        let allowed = (state.flags & HOST_STATE_RADIO_CONFIG_VALID) != 0
            && canTransmit(onFrequency: state.freqTx, bandwidth: state.bw)
        if allowed {
            state.flags |= HOST_STATE_TX_ALLOWED
        } else {
            state.flags &= ~(HOST_STATE_TX_ALLOWED | HOST_STATE_PTT_REQUESTED)
        }
    }

    private func hasDesiredFlag(_ flag: UInt16) -> Bool {
        withLock { (_desiredState.flags & flag) != 0 }
    }

    private func hasDeviceFlag(_ flag: UInt16) -> Bool {
        withLock { lastDeviceState.map { ($0.flags & flag) != 0 } ?? false }
    }

    private func sendDesiredStateIfChanged() {
        guard updateDepth == 0, let send, transportReady else { return }
        guard _desiredState != lastDesiredStateSent else { return }
        // Firmware retries a failed SA818 group command forever, and the
        // module rejects out-of-range frequencies, so one would hang the
        // radio. Drop the whole change (a partial one could pair a new RX
        // with a stale TX frequency).
        guard isConfigTunable(_desiredState) else {
            if let lastDesiredStateSent { _desiredState = lastDesiredStateSent }
            return
        }
        let appliedSequence = lastDeviceState?.appliedSequence ?? _desiredState.sequence
        _desiredState.sequence = max(_desiredState.sequence, appliedSequence) &+ 1
        lastDesiredStateSent = _desiredState
        desiredStateRetries = 0
        _appliedStateInSync = false
        send(_desiredState)
    }

    private func retryDesiredStateIfNeeded() {
        guard let send, transportReady,
              let lastSent = lastDesiredStateSent, _desiredState == lastSent,
              desiredStateRetries < Self.maxDesiredStateRetries
        else { return }
        desiredStateRetries += 1
        send(lastSent)
    }
}
