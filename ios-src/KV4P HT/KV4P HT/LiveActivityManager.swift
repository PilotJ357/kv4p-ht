//
//  LiveActivityManager.swift
//  KV4P HT
//
//  Drives a Live Activity that shows live APRS-monitoring status (last station
//  heard + running packet count) on the Lock Screen and Dynamic Island while
//  connected. The visual is rendered by the APRSMonitorWidget extension; this
//  type only requests/updates/ends the activity.
//
//  HIG: meaningful updates only (throttled), end when the session ends, mark
//  content stale when no packets arrive for a while.
//

import Foundation
import ActivityKit

@MainActor
final class LiveActivityManager {
    private var activity: Activity<APRSActivityAttributes>?
    private var packetCount = 0
    private var lastUpdate = Date.distantPast

    private let minUpdateInterval: TimeInterval = 5
    private let staleAfter: TimeInterval = 30 * 60

    func start(enabled: Bool) {
        guard enabled, activity == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        for stale in Activity<APRSActivityAttributes>.activities {
            let snap = stale
            Task { await snap.end(nil, dismissalPolicy: .immediate) }
        }

        let state = APRSActivityAttributes.ContentState(
            lastCallsign: "—", lastKind: "Monitoring",
            lastText: "Waiting for packets…", packetCount: 0, lastUpdate: Date())
        packetCount = 0
        lastUpdate = .distantPast
        do {
            activity = try Activity.request(
                attributes: APRSActivityAttributes(startedAt: Date()),
                content: .init(state: state, staleDate: nil))
        } catch {
            activity = nil
        }
    }

    func received(_ entry: APRSEntry) {
        guard let activity else { return }
        packetCount += 1
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= minUpdateInterval else { return }
        lastUpdate = now
        let state = APRSActivityAttributes.ContentState(
            lastCallsign: entry.fromCallsign, lastKind: entry.kind.label,
            lastText: String(entry.text.prefix(80)),
            packetCount: packetCount, lastUpdate: now)
        let content = ActivityContent(state: state,
                                      staleDate: now.addingTimeInterval(staleAfter),
                                      relevanceScore: 50)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        let count = packetCount
        self.activity = nil
        packetCount = 0
        let finalState = APRSActivityAttributes.ContentState(
            lastCallsign: "—", lastKind: "Ended",
            lastText: "Session ended", packetCount: count, lastUpdate: Date())
        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate)
        }
    }
}
