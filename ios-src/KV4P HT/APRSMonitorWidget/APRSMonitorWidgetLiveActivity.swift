//
//  APRSMonitorWidgetLiveActivity.swift
//  APRSMonitorWidget
//
//  Lock Screen + Dynamic Island presentation for the APRS monitoring activity.
//  State is supplied by LiveActivityManager in the main app via the shared
//  APRSActivityAttributes type. Glanceable only — no interactive controls (HIG).
//

import ActivityKit
import WidgetKit
import SwiftUI

struct APRSMonitorWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: APRSActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .widgetURL(URL(string: "kv4pht://aprs"))
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Keep all four top regions (leading/trailing/center) empty so no
                // content lands in the rounded corners beside the camera. Put the
                // entire layout in the full-width bottom region.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("APRS", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption).foregroundStyle(.green)
                            Spacer()
                            Text("\(context.state.packetCount) packets")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(context.state.lastCallsign) · \(context.state.lastKind)")
                            .font(.headline)
                        Text(context.state.lastText)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.packetCount)")
                    .font(.system(.caption, design: .monospaced))
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}

private struct LockScreenView: View {
    let state: APRSActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.lastCallsign) · \(state.lastKind)")
                    .font(.headline)
                Text(state.lastText)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(spacing: 0) {
                Text("\(state.packetCount)")
                    .font(.system(.title2, design: .monospaced)).bold()
                Text("packets").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
