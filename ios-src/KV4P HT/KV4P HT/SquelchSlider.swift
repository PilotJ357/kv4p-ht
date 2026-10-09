import SwiftUI

// Squelch level 0...9. The slider is continuous so the thumb tracks the finger
// like the volume slider; a stepped Slider hops between detents and lags
// behind the drag. The level shown and stored is the rounded value, and the
// thumb lands on it at release. Drags send the level to the radio once, on
// release (per-tick writes made the thumb bounce); VoiceOver adjustments send
// it immediately.
struct SquelchSlider: View {
    @Bindable var store: RadioStore
    // Raw thumb position while dragging; nil otherwise.
    @State private var dragValue: Double?

    var body: some View {
        Slider(
            value: Binding(
                get: { dragValue ?? Double(store.squelch) },
                set: { v in
                    let level = UInt8(v.rounded())
                    if dragValue != nil {
                        dragValue = v
                        if store.squelch != level { store.squelch = level }
                    } else {
                        set(level)
                    }
                }
            ),
            in: 0...9
        ) { editing in
            if editing {
                dragValue = Double(store.squelch)
            } else {
                dragValue = nil
                store.radio.setSquelch(store.squelch)
            }
        }
        .accessibilityLabel("Squelch")
        .accessibilityValue("\(store.squelch)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if store.squelch < 9 { set(store.squelch + 1) }
            case .decrement: if store.squelch > 0 { set(store.squelch - 1) }
            @unknown default: break
            }
        }
    }

    private func set(_ level: UInt8) {
        store.squelch = level
        store.radio.setSquelch(level)
    }
}
