import SwiftUI

// MARK: - Device strip (hardware connection status)

struct DeviceStrip: View {
    @Environment(\.theme) var t
    var connected: Bool
    var demo: Bool = false
    var battery: Int? = nil   // nil = no data from device yet
    var label: String = "KV4P BLE"
    var action: () -> Void = {}

    private var dotColor: Color { !connected ? t.red : demo ? t.amber : t.green }

    var body: some View {
        Button(action: action) { HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor, radius: 3)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.footnote.weight(.medium))
                .foregroundStyle(t.label2)
            Text(connected && demo ? "Demo radio" : label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(t.label)
                .lineLimit(1)
            Text(!connected ? "Disconnected" : demo ? "Simulated" : "Connected")
                .font(.footnote)
                .foregroundStyle(t.label2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let batt = battery {
                BattGlyph(pct: batt)
                Text("\(batt)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(t.label2)
            }
            // Tells it apart from a text field: tapping opens the radio picker.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(t.label3)
                .accessibilityHidden(true)
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .glassTile(cornerRadius: 12, interactive: true, fallback: t.fill2)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose a radio")
    }
}

struct BattGlyph: View {
    @Environment(\.theme) var t
    var pct: Int

    var body: some View {
        let col = pct < 20 ? t.red : t.label2
        Canvas { ctx, size in
            let w: CGFloat = 22
            // Outline
            let outline = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w, height: 12), cornerRadius: 3)
            ctx.stroke(outline, with: .color(col.opacity(0.45)), lineWidth: 1)
            // Fill
            let fillW = max(2, (w - 4) * CGFloat(pct) / 100)
            let fill = Path(roundedRect: CGRect(x: 2, y: 2, width: fillW, height: 8), cornerRadius: 1.5)
            ctx.fill(fill, with: .color(col))
            // Nub
            let nub = Path(roundedRect: CGRect(x: w + 1.5, y: 3.5, width: 2.5, height: 5), cornerRadius: 1.2)
            ctx.fill(nub, with: .color(col.opacity(0.45)))
        }
        .frame(width: 26, height: 13)
    }
}

// MARK: - S-Meter

struct SMeter: View {
    @Environment(\.theme) var t
    var level: Int     // 0-13, see SMeterScale
    var max: Int = SMeterScale.maxBars
    var tx: Bool = false
    var active: Bool = true
    var rawRSSI: UInt8 = 0
    @State private var showRSSI = false

    // S1–S9 green, over-S9 amber, overload red; every lit bar red in TX.
    private func color(bar i: Int) -> Color {
        if tx { return t.red }
        if i >= SMeterScale.overloadBar - 1 { return t.red }
        if i >= SMeterScale.s9Bar { return t.amber }
        return t.green
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<max, id: \.self) { i in
                let on = active && i < level
                let h: CGFloat = 8 + CGFloat(i) / CGFloat(max - 1) * 18
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(on ? color(bar: i) : t.meterTrack)
                    .frame(width: 5, height: h)
                    .animation(.easeOut(duration: 0.15), value: on)
            }
            if showRSSI {
                Text("RSSI \(rawRSSI)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(t.label2)
                    .transition(.opacity)
            }
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showRSSI.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("S-meter")
        .accessibilityValue(SMeterScale.description(bars: active ? level : 0, tx: tx))
    }
}

// MARK: - Settings icon tile

struct IconTile: View {
    @Environment(\.theme) var t
    var color: Color
    var systemImage: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    // Night stays dark on red so no white pixels break dark adaptation.
                    .foregroundStyle(t.mode == .night ? t.bg : Color.white)
            )
    }
}

// MARK: - RX/TX badge

struct RxBadge: View {
    @Environment(\.theme) var t
    var state: RadioRxState

    private var color: Color {
        switch state {
        case .idle: return t.label3
        case .rx:   return t.green
        case .tx:   return t.red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: state == .idle ? .clear : color, radius: 4)
            // Size to the widest label so the centered S-meter row
            // doesn't shift when the state text changes (#132).
            ZStack(alignment: .leading) {
                ForEach(RadioRxState.allCases, id: \.self) { s in
                    Text(s.label).hidden()
                }
                Text(state.label)
                    .foregroundStyle(color)
            }
            .font(.caption.weight(.bold))
            .tracking(0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.label)
        }
    }
}

// MARK: - Info pill (offset / tone / power)
// Tappable glass tile; callers wrap it in a Button or Menu.

struct InfoPill: View {
    @Environment(\.theme) var t
    var key: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(t.label2)
                .lineLimit(1)
            // Default design so words ("Simplex", "High") match the rest of the
            // UI; tabular digits keep numbers aligned.
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(t.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .glassTile(cornerRadius: 13, interactive: true, fallback: t.fill2)
    }
}

// MARK: - Liquid Glass with pre-iOS 26 fallbacks

extension View {
    /// `.glass` on iOS 26; `.bordered` before.
    @ViewBuilder func glassButtonStyle() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    /// `.glassProminent` on iOS 26; `.borderedProminent` before.
    @ViewBuilder func glassProminentButtonStyle() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// Glass behind a tile on iOS 26; a plain fill in the same shape before.
    func glassTile<S: ShapeStyle>(cornerRadius: CGFloat, interactive: Bool = false,
                                  fallback: S) -> some View {
        modifier(GlassTile(cornerRadius: cornerRadius, interactive: interactive, fallback: fallback))
    }
}

private struct GlassTile<S: ShapeStyle>: ViewModifier {
    @Environment(\.theme) var t
    var cornerRadius: CGFloat
    var interactive: Bool
    var fallback: S

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // Untinted glass reads neutral grey over black; tint it red in Night.
            let glass: Glass = t.mode == .night ? .regular.tint(t.surface2) : .regular
            content.glassEffect(interactive ? glass.interactive() : glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(fallback, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// The system close (X) button on iOS 26; a "Close" text button before.
struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button("Close", action: action)
        }
    }
}
