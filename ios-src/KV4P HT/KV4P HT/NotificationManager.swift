//
//  NotificationManager.swift
//  KV4P HT
//
//  Local notifications for received APRS packets. No server / APNs: the app
//  decodes APRS in the background (UIBackgroundModes audio + bluetooth-central),
//  so a received frame can post a local notification directly.
//
//  Scope: per-kind filtering, "addressed to me" gating, distance filter, a
//  per-(callsign,kind) cooldown to tame SmartBeacon floods, and per-station mute.
//

import Foundation
import UserNotifications

// MARK: - Settings

// Persisted in RadioStore under its own UserDefaults key. All packet kinds
// default ON; the master `enabled` flag is what actually gates delivery.
struct APRSNotifySettings: Codable, Equatable {
    var enabled: Bool = false
    // Keyed by APRSPacketKind.rawValue. Missing key ⇒ treated as enabled.
    var perKind: [String: Bool] = APRSNotifySettings.allKindsOn
    var onlyMessagesToMe: Bool = false
    var distanceFilterMi: Double? = nil
    var cooldownSec: Double = 300
    var mutedCallsigns: Set<String> = []
    var liveActivityEnabled: Bool = true

    static var allKindsOn: [String: Bool] {
        Dictionary(uniqueKeysWithValues:
            [APRSPacketKind.message, .bulletin, .weather, .position, .object, .raw]
                .map { ($0.rawValue, true) })
    }

    func kindEnabled(_ kind: APRSPacketKind) -> Bool { perKind[kind.rawValue] ?? true }
}

// MARK: - Decision gate (pure, unit-testable; no UNUserNotificationCenter)

enum NotifyGate {
    struct Context {
        var isAddressedToMe: Bool
        var distanceMi: Double?
        // Last time a notification fired for this (callsign-base, kind), if any.
        var lastNotifiedAt: Date?
    }

    // A directed message addressed to us is high-value and rare: always fire,
    // bypassing the cooldown. Everything else (position/weather/object/bulletin/
    // raw, and broadcast messages) is throttled per (callsign, kind).
    static func isHighPriority(_ entry: APRSEntry, addressedToMe: Bool) -> Bool {
        entry.kind == .message && addressedToMe
    }

    static func shouldFire(_ entry: APRSEntry,
                           settings: APRSNotifySettings,
                           context ctx: Context,
                           now: Date) -> Bool {
        guard settings.enabled, !entry.isOutgoing else { return false }
        guard settings.kindEnabled(entry.kind) else { return false }

        if settings.mutedCallsigns.contains(baseCallsign(entry.fromCallsign)) { return false }

        if entry.kind == .message && settings.onlyMessagesToMe && !ctx.isAddressedToMe {
            return false
        }

        if let limit = settings.distanceFilterMi {
            // No position ⇒ can't distance-filter; let it through.
            if let d = ctx.distanceMi, d > limit { return false }
        }

        if isHighPriority(entry, addressedToMe: ctx.isAddressedToMe) { return true }

        // Cooldown throttle.
        if let last = ctx.lastNotifiedAt, now.timeIntervalSince(last) < settings.cooldownSec {
            return false
        }
        return true
    }

    // Strip the SSID ("-9") so all of a station's beacons share one throttle slot.
    static func baseCallsign(_ s: String) -> String {
        String(s.split(separator: "-", maxSplits: 1).first ?? Substring(s)).uppercased()
    }

    static func throttleKey(_ entry: APRSEntry) -> String {
        "\(baseCallsign(entry.fromCallsign))|\(entry.kind.rawValue)"
    }
}

// MARK: - Notifier protocol (lets tests inject a spy)

protocol APRSNotifying: AnyObject {
    func consider(_ entry: APRSEntry,
                  settings: APRSNotifySettings,
                  isAddressedToMe: Bool,
                  distanceMi: Double?,
                  now: Date)
}

extension APRSNotifying {
    func consider(_ entry: APRSEntry, settings: APRSNotifySettings,
                  isAddressedToMe: Bool, distanceMi: Double?) {
        consider(entry, settings: settings, isAddressedToMe: isAddressedToMe,
                 distanceMi: distanceMi, now: Date())
    }
}

// MARK: - NotificationManager

final class NotificationManager: NSObject, APRSNotifying, UNUserNotificationCenterDelegate {
    static let messageCategory = "aprs.message"
    static let beaconCategory  = "aprs.beacon"

    private static let replyAction = "aprs.reply"
    private static let muteAction  = "aprs.mute"
    private static let openAction  = "aprs.open"

    private let center = UNUserNotificationCenter.current()
    // Per-(callsign,kind) last-fired timestamps for the cooldown throttle.
    private var lastNotified: [String: Date] = [:]

    // Wired by RadioStore so notification actions can act on the controller.
    var onReply: ((_ to: String, _ text: String) -> Void)?
    var onMute:  ((_ callsignBase: String) -> Void)?
    var onOpen:  ((_ entryID: UUID?, _ lat: Double?, _ lon: Double?) -> Void)?

    func configure() {
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let mute = UNNotificationAction(
            identifier: Self.muteAction, title: "Mute Station", options: [.destructive])
        let open = UNNotificationAction(
            identifier: Self.openAction, title: "Open Map", options: [.foreground])

        let message = UNNotificationCategory(
            identifier: Self.messageCategory, actions: [reply, mute],
            intentIdentifiers: [], options: [])
        let beacon = UNNotificationCategory(
            identifier: Self.beaconCategory, actions: [open, mute],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([message, beacon])
    }

    // MARK: Authorization

    // Explicit request; HIG: call at the point of intent (master toggle on).
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in
            DispatchQueue.main.async { completion(s.authorizationStatus) }
        }
    }

    // MARK: Delivery

    func consider(_ entry: APRSEntry, settings: APRSNotifySettings,
                  isAddressedToMe: Bool, distanceMi: Double?, now: Date) {
        let key = NotifyGate.throttleKey(entry)
        let ctx = NotifyGate.Context(isAddressedToMe: isAddressedToMe,
                                     distanceMi: distanceMi,
                                     lastNotifiedAt: lastNotified[key])
        guard NotifyGate.shouldFire(entry, settings: settings, context: ctx, now: now)
        else { return }
        lastNotified[key] = now
        post(entry, addressedToMe: isAddressedToMe)
    }

    private func post(_ entry: APRSEntry, addressedToMe: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(entry.fromCallsign) · \(entry.kind.label)"
        content.body = String(entry.text.prefix(160))
        // Group all of a station's packets together.
        content.threadIdentifier = entry.fromCallsign

        let isMsgToMe = entry.kind == .message && addressedToMe
        content.categoryIdentifier = entry.kind == .message ? Self.messageCategory
                                                             : Self.beaconCategory
        content.interruptionLevel = isMsgToMe ? .timeSensitive
            : (entry.kind == .message || entry.kind == .bulletin ? .active : .passive)
        content.relevanceScore = isMsgToMe ? 1.0
            : (entry.kind == .message || entry.kind == .bulletin ? 0.5 : 0.2)
        if isMsgToMe { content.sound = .default }

        var info: [String: Any] = ["entryID": entry.id.uuidString,
                                   "from": entry.fromCallsign]
        if let lat = entry.lat { info["lat"] = lat }
        if let lon = entry.lon { info["lon"] = lon }
        content.userInfo = info

        let req = UNNotificationRequest(identifier: entry.id.uuidString,
                                        content: content, trigger: nil)
        center.add(req)
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show banners even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let from = info["from"] as? String ?? ""
        let entryID = (info["entryID"] as? String).flatMap(UUID.init)
        let lat = info["lat"] as? Double
        let lon = info["lon"] as? Double

        switch response.actionIdentifier {
        case Self.replyAction:
            if let text = (response as? UNTextInputNotificationResponse)?.userText,
               !text.isEmpty, !from.isEmpty {
                onReply?(from, text)  // reply to the sender's full callsign+SSID
            }
        case Self.muteAction:
            if !from.isEmpty { onMute?(NotifyGate.baseCallsign(from)) }
        case Self.openAction, UNNotificationDefaultActionIdentifier:
            onOpen?(entryID, lat, lon)
        default:
            break
        }
        handler()
    }
}
