import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

@Suite struct DirectionsAppTests {
    private let destination = CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03)

    private func defaults(choosing app: DirectionsApp?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let app { defaults.set(app.rawValue, forKey: DirectionsApp.storageKey) }
        return defaults
    }

    @Test func onlyInstalledAppsAreOffered() {
        #expect(DirectionsApp.installed { _ in false } == [.appleMaps])
        #expect(DirectionsApp.installed { $0.scheme == "citymapper" } == [.appleMaps, .citymapper])
        #expect(DirectionsApp.installed { _ in true } == DirectionsApp.allCases)
    }

    @Test func preferredFallsBackToAppleMaps() {
        let everything: (URL) -> Bool = { _ in true }
        let nothing: (URL) -> Bool = { _ in false }
        #expect(DirectionsApp.preferred(defaults: defaults(choosing: nil), canOpen: everything) == .appleMaps)
        #expect(DirectionsApp.preferred(defaults: defaults(choosing: .googleMaps), canOpen: everything) == .googleMaps)
        // Chosen, then deleted from the phone.
        #expect(DirectionsApp.preferred(defaults: defaults(choosing: .googleMaps), canOpen: nothing) == .appleMaps)
    }

    @Test func links() {
        #expect(DirectionsApp.appleMaps.directions(to: destination)?.absoluteString
                == "https://maps.apple.com/directions?destination=37.330000,-122.030000&mode=cycling")
        #expect(DirectionsApp.googleMaps.directions(to: destination)?.absoluteString
                == "https://www.google.com/maps/dir/?api=1&destination=37.330000,-122.030000&travelmode=bicycling")
        #expect(DirectionsApp.citymapper.directions(to: destination, name: "Start of Hill Loop")?.absoluteString
                == "citymapper://directions?endcoord=37.330000,-122.030000&endname=Start%20of%20Hill%20Loop")
    }
}
