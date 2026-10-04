//
//  APRSActivityAttributes.swift
//  KV4P HT
//
//  Shared Live Activity model. This file must belong to BOTH the app target and
//  the widget-extension target so the app can drive the activity and the widget
//  can render it. (In Xcode: File Inspector › Target Membership → check both.)
//

import Foundation
import ActivityKit

struct APRSActivityAttributes: ActivityAttributes {
    // Mutable per-update content shown on the Lock Screen / Dynamic Island.
    public struct ContentState: Codable, Hashable {
        var lastCallsign: String
        var lastKind: String
        var lastText: String
        var packetCount: Int
        var lastUpdate: Date
    }

    // Static for the life of the activity.
    var startedAt: Date
}
