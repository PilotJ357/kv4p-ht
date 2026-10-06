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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(t.label2)
            Text(connected && demo ? "Demo radio" : label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.label)
            Text(!connected ? "Disconnected" : demo ? "Simulated" : "Connected")
                .font(.system(size: 13))
                .foregroundStyle(t.label2)
            Spacer()
            if let batt = battery {
                BattGlyph(pct: batt)
                Text("\(batt)%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
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
    var level: Int     // 0-9
    var max: Int = 9
    var active: Bool = true
    var rawRSSI: UInt8 = 0
    @State private var showRSSI = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<max, id: \.self) { i in
                let on = active && i < level
                let h: CGFloat = 8 + CGFloat(i) / CGFloat(max - 1) * 18
                let col: Color = i >= 6 ? t.red : i >= 4 ? t.amber : t.green
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? col : t.meterTrack)
                    .frame(width: 6, height: h)
                    .animation(.easeOut(duration: 0.15), value: on)
            }
            if showRSSI {
                Text("RSSI \(rawRSSI)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.label2)
                    .transition(.opacity)
            }
        }
        .frame(height: 26)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showRSSI.toggle() }
        }
    }
}

// MARK: - Settings icon tile

struct IconTile: View {
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
                    .foregroundStyle(.white)
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
            Text(state.label)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(color)
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
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(t.label2)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.label)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
    }
}
