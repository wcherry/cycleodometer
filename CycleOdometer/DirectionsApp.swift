import CoreLocation
import Foundation
import UIKit

/// The app that opens directions handed off from Cycle (to a route's start, say).
/// Chosen in Settings; only apps that are installed are offered.
enum DirectionsApp: String, CaseIterable, Identifiable {
    case appleMaps, googleMaps, citymapper

    static let storageKey = "directionsApp"

    var id: Self { self }

    var name: String {
        switch self {
        case .appleMaps: "Apple Maps"
        case .googleMaps: "Google Maps"
        case .citymapper: "Citymapper"
        }
    }

    /// How to tell it's installed. Each scheme is listed in Info.plist's
    /// LSApplicationQueriesSchemes, or iOS always answers no.
    private var scheme: URL? {
        switch self {
        case .appleMaps: nil
        case .googleMaps: URL(string: "comgooglemaps://")
        case .citymapper: URL(string: "citymapper://")
        }
    }

    /// Apple Maps is always there; the others only if installed.
    static func installed(canOpen: (URL) -> Bool = { UIApplication.shared.canOpenURL($0) }) -> [DirectionsApp] {
        allCases.filter { app in app.scheme.map(canOpen) ?? true }
    }

    /// The rider's choice, or Apple Maps if nothing's chosen or it's since been deleted.
    static func preferred(defaults: UserDefaults = .standard,
                          canOpen: (URL) -> Bool = { UIApplication.shared.canOpenURL($0) }) -> DirectionsApp {
        guard let chosen = defaults.string(forKey: storageKey).flatMap(DirectionsApp.init(rawValue:)),
              installed(canOpen: canOpen).contains(chosen) else { return .appleMaps }
        return chosen
    }

    /// Directions from wherever you are to `destination`, cycling where the app has it.
    func directions(to destination: CLLocationCoordinate2D, name: String? = nil) -> URL? {
        switch self {
        case .appleMaps:
            MapLinks.appleDirections(to: destination)
        case .googleMaps:
            MapLinks.googleDirections(to: destination)
        case .citymapper:
            // Citymapper offers its cycling options alongside the others; there's no
            // parameter to pick one.
            MapLinks.citymapperDirections(to: destination, name: name)
        }
    }
}
