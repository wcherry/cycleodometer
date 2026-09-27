import CoreLocation
import Foundation
import MapKit

/// One step of Apple's directions: its instruction, and the path it covers.
struct DirectionsStep: Equatable {
    var instructions: String
    var coordinates: [CLLocationCoordinate2D]

    static func == (a: Self, b: Self) -> Bool {
        a.instructions == b.instructions && a.coordinates.count == b.coordinates.count
    }
}

struct DirectionsRoute {
    var coordinates: [CLLocationCoordinate2D]
    var steps: [DirectionsStep]
    /// Apple's estimate, in metres and seconds.
    var distance: Double = 0
    var expectedTravelTime: TimeInterval = 0
    /// Apple's name for the route, usually its main road ("Stevens Creek Blvd").
    var name: String = ""
}

/// Apple's cycling directions and street lookups. A protocol so tests can stand in
/// canned answers for the network.
protocol DirectionsProvider {
    /// Apple's cycling routes, best first; more than one when `alternatives` is set
    /// and Apple has them.
    func cyclingRoutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       alternatives: Bool) async throws -> [DirectionsRoute]
    /// The street at a point, e.g. "Main St".
    func streetName(near: CLLocationCoordinate2D) async throws -> String?
}

extension DirectionsProvider {
    func cyclingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> DirectionsRoute {
        guard let route = try await cyclingRoutes(from: from, to: to, alternatives: false).first else {
            throw MapKitDirections.NoRoute()
        }
        return route
    }
}

struct MapKitDirections: DirectionsProvider {
    struct NoRoute: Error {}

    func cyclingRoutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       alternatives: Bool) async throws -> [DirectionsRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = .cycling
        request.requestsAlternateRoutes = alternatives
        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw NoRoute() }
        return response.routes.map { route in
            DirectionsRoute(
                coordinates: route.polyline.coordinates,
                steps: route.steps.map { DirectionsStep(instructions: $0.instructions, coordinates: $0.polyline.coordinates) },
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                name: route.name
            )
        }
    }

    func streetName(near coordinate: CLLocationCoordinate2D) async throws -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let item = try await request.mapItems.first else { return nil }
        return Self.street(from: item.address?.shortAddress ?? item.name)
    }

    /// "1 Infinite Loop, Cupertino" → "Infinite Loop": the first part, less any
    /// house number.
    static func street(from address: String?) -> String? {
        guard let first = address?.split(separator: ",").first else { return nil }
        let words = first.split(separator: " ")
        let street = words.drop { $0.first?.isNumber == true }.joined(separator: " ")
        return street.isEmpty ? nil : street
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}

/// Finds the name of the street each turn leads onto. See "Turn cues" in
/// docs/features/routes-and-maps.md.
enum StreetNames {
    enum Lookup: Equatable {
        case found(String)
        /// Apple answered, but with no street name for this turn.
        case notFound
        /// Apple couldn't be reached (offline, throttled): worth asking again later.
        case failed
    }

    /// Apple's route for a leg must stay this close to ours for its names to be used.
    static let matchTolerance = 25.0
    /// Apple's step must begin this close to our turn to be the same turn.
    static let turnTolerance = 30.0

    /// The street after `turns[index]`: from Apple's directions for the leg that
    /// follows it, if Apple's leg is the same road as ours; otherwise from a street
    /// lookup just past the turn.
    static func name(forTurn index: Int, of turns: [Turn], on line: Polyline,
                     using provider: DirectionsProvider) async -> Lookup {
        let turn = turns[index]
        let legStart = max(turn.along - 40, 0)
        let nextTurn = index + 1 < turns.count ? turns[index + 1].along : line.length
        let legEnd = min(max(nextTurn - 20, turn.along + 30), line.length)
        let from = line.coordinate(line.point(at: legStart))
        let to = line.coordinate(line.point(at: legEnd))

        let route = try? await provider.cyclingRoute(from: from, to: to)
        if let route, follows(route.coordinates, line),
           let step = route.steps.first(where: { step in
               guard let first = step.coordinates.first else { return false }
               return distance(first, turn.coordinate) <= turnTolerance && !step.instructions.isEmpty
           }),
           let name = DirectionText.streetName(in: step.instructions) {
            return .found(name)
        }

        let justPast = line.coordinate(line.point(at: min(turn.along + 30, line.length)))
        do {
            return try await provider.streetName(near: justPast).map(Lookup.found) ?? .notFound
        } catch {
            return route == nil ? .failed : .notFound
        }
    }

    /// Whether every point of Apple's route lies within `matchTolerance` of ours.
    static func follows(_ coordinates: [CLLocationCoordinate2D], _ line: Polyline) -> Bool {
        !coordinates.isEmpty && coordinates.allSatisfy { line.nearest(to: $0).distance <= matchTolerance }
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// Apple's directions for getting somewhere that isn't on the route: to its start
/// (Ride to Start), or back onto it after going off route.
struct GuidanceLeg {
    enum Purpose: Equatable {
        case toStart
        case backToRoute
    }

    /// Wander this far from the leg for this long and it's recalculated.
    static let strayDistance = 60.0
    static let strayDelay: TimeInterval = 20

    let purpose: Purpose
    let line: Polyline
    /// Where each step's manoeuvre is along `line`, with its instruction.
    let steps: [(along: Double, instructions: String)]
    private(set) var progress = 0.0
    private(set) var strayingSince: Date?

    init?(purpose: Purpose, route: DirectionsRoute) {
        guard let line = Polyline(route.coordinates) else { return nil }
        self.purpose = purpose
        self.line = line
        steps = Self.steps(of: route, on: line)
    }

    /// Where each of Apple's instructions applies along `line`. The first step is
    /// Apple's "start" and has no manoeuvre, so it's left out.
    static func steps(of route: DirectionsRoute, on line: Polyline) -> [(along: Double, instructions: String)] {
        route.steps.dropFirst().compactMap { step in
            guard let first = step.coordinates.first, !step.instructions.isEmpty else { return nil }
            return (line.nearest(to: first).along, step.instructions)
        }
    }

    var remaining: Double { max(line.length - progress, 0) }

    /// The next instruction ahead, and how far away it is.
    var nextStep: (index: Int, instructions: String, distance: Double)? {
        guard let index = steps.firstIndex(where: { $0.along > progress + 5 }) else { return nil }
        return (index, steps[index].instructions, steps[index].along - progress)
    }

    /// Moves along the leg. Returns false once you've strayed from it long enough
    /// that it should be recalculated.
    mutating func update(_ position: CLLocationCoordinate2D, at time: Date) -> Bool {
        let nearest = line.nearest(to: position)
        if nearest.distance > Self.strayDistance {
            let since = strayingSince ?? time
            strayingSince = since
            return time.timeIntervalSince(since) < Self.strayDelay
        }
        strayingSince = nil
        progress = max(progress, nearest.along)
        return true
    }
}
