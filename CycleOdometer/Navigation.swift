import CoreLocation
import Foundation
import Observation

/// A place to navigate to.
struct Destination: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// e.g. its address.
    var subtitle: String?
    var latitude: Double
    var longitude: Double

    init(name: String, subtitle: String? = nil, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.subtitle = subtitle
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Navigating to a place along Apple's cycling route. The route itself is followed
/// like any other (`RouteFollower`); this holds what's particular to navigating: the
/// destination, Apple's step-by-step instructions, and its time estimate.
struct Navigation {
    var destination: Destination
    /// Where each instruction applies along the route, e.g. "Turn right onto Main St".
    var steps: [(along: Double, instructions: String)]
    /// Apple's estimate for the whole route, and the route's length, in metres.
    var expectedTravelTime: TimeInterval
    var routeLength: Double

    init(destination: Destination, route: DirectionsRoute, line: Polyline) {
        self.destination = destination
        steps = GuidanceLeg.steps(of: route, on: line)
        expectedTravelTime = route.expectedTravelTime
        routeLength = line.length
    }

    /// Apple's estimate, scaled to how much of the route is left.
    func timeLeft(remaining: Double) -> TimeInterval {
        routeLength > 0 ? expectedTravelTime * remaining / routeLength : 0
    }

    /// e.g. "12 min left", "1 h 5 min left".
    static func timeLeftText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case ..<1: return "Under 1 min left"
        case ..<60: return "\(minutes) min left"
        default: return minutes % 60 == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(minutes % 60) min left"
        }
    }
}

/// The last few places navigated to, newest first, kept only on this phone.
@Observable
final class RecentDestinations {
    static let limit = 10
    /// A place this close to one already in the list replaces it rather than
    /// being listed twice.
    static let samePlaceDistance = 50.0

    private(set) var items: [Destination] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "destinations.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Destination].self, from: data) {
            items = saved
        }
    }

    func add(_ destination: Destination) {
        let here = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        items.removeAll {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here) < Self.samePlaceDistance
        }
        items.insert(destination, at: 0)
        items = Array(items.prefix(Self.limit))
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // Only a convenience; not worth interrupting anyone over.
        }
    }
}
