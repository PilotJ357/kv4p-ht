import Foundation
import CoreLocation
import Observation

/// Whether the app can get a location fix, folded from the per-app
/// authorization and the system-wide Location Services switch.
nonisolated enum LocationAccess: Equatable {
    case notDetermined, denied, restricted, servicesOff, authorized

    // Location Services off system-wide reports `.denied` per app, so the
    // global switch wins; restricted (parental controls / MDM) can't be
    // changed by the user at all, so it wins over both.
    init(status: CLAuthorizationStatus, servicesEnabled: Bool) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .authorized
        case .restricted:                             self = .restricted
        case _ where !servicesEnabled:                self = .servicesOff
        case .denied:                                 self = .denied
        default:                                      self = .notDetermined
        }
    }

    /// True once asking again can't help — the user has to go to Settings.
    var isUnavailable: Bool {
        switch self {
        case .denied, .restricted, .servicesOff: return true
        case .notDetermined, .authorized:        return false
        }
    }

    /// What to tell the user when location is unavailable; nil otherwise.
    var explanation: String? {
        switch self {
        case .denied:
            return "Location access is off for Pocket HT. Allow it in Settings › Pocket HT › Location."
        case .restricted:
            return "Location access is restricted on this device (Screen Time or device management)."
        case .servicesOff:
            return "Location Services are turned off. Turn them on in Settings › Privacy & Security › Location Services."
        case .notDetermined, .authorized:
            return nil
        }
    }

    /// "Beacon now" status when no fix is available yet.
    var beaconStatus: String {
        switch self {
        case .authorized:    return "Getting your location — try again in a moment"
        case .notDetermined: return "Allow location access to send a beacon"
        case .denied:        return "Not sent — location access is off for Pocket HT"
        case .restricted:    return "Not sent — location access is restricted on this device"
        case .servicesOff:   return "Not sent — Location Services are turned off"
        }
    }
}

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    var location: CLLocation?
    private(set) var access: LocationAccess = .notDetermined
    var isLoading: Bool = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        // Provisional until the first delegate callback checks the global switch.
        access = LocationAccess(status: manager.authorizationStatus, servicesEnabled: true)
    }

    /// `location` if it was fixed within `maxAge`; nil when missing or stale.
    func location(maxAge: TimeInterval, now: Date = Date()) -> CLLocation? {
        guard let location, Self.isFresh(location, maxAge: maxAge, now: now) else { return nil }
        return location
    }

    /// A fix no older than `maxAge`, requesting a new one and waiting up to
    /// `timeout` when the cached fix is missing or stale. Returns nil if none
    /// arrives (or access isn't granted), so callers never act on an old fix.
    func freshLocation(maxAge: TimeInterval, timeout: Duration = .seconds(10)) async -> CLLocation? {
        if let loc = location(maxAge: maxAge) { return loc }
        requestLocation()
        guard access == .authorized else { return nil }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            if let loc = location(maxAge: maxAge) { return loc }
            if !isLoading { break }   // request finished (or failed) without a fresh fix
        }
        return location(maxAge: maxAge)
    }

    nonisolated static func isFresh(_ location: CLLocation, maxAge: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(location.timestamp) <= maxAge
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse, .authorizedAlways:
            isLoading = true
            manager.requestLocation()

        default:
            // Denied/restricted/services off: nothing to ask; `access`
            // tells the UI why.
            refresh()
        }
    }

    /// Re-read authorization and the global Location Services switch, e.g.
    /// when returning from Settings.
    func refresh() {
        let status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            access = .authorized
            return
        }
        // locationServicesEnabled() can block, so keep it off the main thread.
        Task {
            let enabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
            access = LocationAccess(status: manager.authorizationStatus, servicesEnabled: enabled)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            isLoading = true
            manager.requestLocation()
        default:
            // Access revoked: don't keep beaconing a cached position.
            location = nil
            isLoading = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            isLoading = false
            return
        }

        location = loc
        isLoading = false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLoading = false
    }
}
