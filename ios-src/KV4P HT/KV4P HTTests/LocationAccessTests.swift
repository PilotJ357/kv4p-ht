import CoreLocation
import Testing
@testable import KV4P_HT

struct LocationAccessTests {

    @Test func authorizedRegardlessOfServicesFlag() {
        // An authorized status implies services are on; never misreport it.
        for status in [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways] {
            #expect(LocationAccess(status: status, servicesEnabled: true) == .authorized)
            #expect(LocationAccess(status: status, servicesEnabled: false) == .authorized)
        }
    }

    @Test func perAppStatesWithServicesOn() {
        #expect(LocationAccess(status: .notDetermined, servicesEnabled: true) == .notDetermined)
        #expect(LocationAccess(status: .denied, servicesEnabled: true) == .denied)
        #expect(LocationAccess(status: .restricted, servicesEnabled: true) == .restricted)
    }

    @Test func servicesOffOverridesDeniedAndNotDetermined() {
        // With Location Services off system-wide iOS reports .denied per app.
        #expect(LocationAccess(status: .denied, servicesEnabled: false) == .servicesOff)
        #expect(LocationAccess(status: .notDetermined, servicesEnabled: false) == .servicesOff)
    }

    @Test func restrictedWinsOverServicesOff() {
        #expect(LocationAccess(status: .restricted, servicesEnabled: false) == .restricted)
    }

    @Test func unavailableStatesExplainThemselves() {
        for access in [LocationAccess.denied, .restricted, .servicesOff] {
            #expect(access.isUnavailable)
            #expect(access.explanation?.isEmpty == false)
            #expect(access.beaconStatus.hasPrefix("Not sent"))
        }
    }

    @Test func availableStatesHaveNoExplanation() {
        for access in [LocationAccess.notDetermined, .authorized] {
            #expect(!access.isUnavailable)
            #expect(access.explanation == nil)
            #expect(!access.beaconStatus.hasPrefix("Not sent"))
        }
    }

    @Test func beaconStatusNoLongerWaitsForever() {
        // Regression for #46: denial used to read "Waiting for GPS fix".
        #expect(!LocationAccess.denied.beaconStatus.contains("Waiting"))
        #expect(LocationAccess.servicesOff.beaconStatus.contains("Location Services"))
    }
}

// MARK: - Fix freshness (#49: never beacon a stale cached position)

struct LocationFreshnessTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func fix(age: TimeInterval) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 37, longitude: -122), altitude: 0,
                   horizontalAccuracy: 100, verticalAccuracy: -1,
                   timestamp: now.addingTimeInterval(-age))
    }

    @Test func recentFixIsFresh() {
        #expect(LocationManager.isFresh(fix(age: 60), maxAge: APRSController.beaconFixMaxAge, now: now))
    }

    @Test func fixAtLimitIsFresh() {
        let max = APRSController.beaconFixMaxAge
        #expect(LocationManager.isFresh(fix(age: max), maxAge: max, now: now))
    }

    @Test func oldFixIsStale() {
        let max = APRSController.beaconFixMaxAge
        #expect(!LocationManager.isFresh(fix(age: max + 1), maxAge: max, now: now))
    }
}
