import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

private let lat0 = 37.33, lon0 = -122.03

private func at(_ north: Double, _ east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat0 + north / 110_540,
                           longitude: lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
}

private func points(_ corners: [(Double, Double)]) -> [CLLocationCoordinate2D] {
    var result: [CLLocationCoordinate2D] = []
    for (a, b) in zip(corners, corners.dropFirst()) {
        let steps = max(Int((hypot(b.0 - a.0, b.1 - a.1) / 10).rounded()), 1)
        for i in 0..<steps {
            let t = Double(i) / Double(steps)
            result.append(at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
        }
    }
    result.append(at(corners.last!.0, corners.last!.1))
    return result
}

/// Canned answers instead of Apple's servers.
final class FakeDirections: DirectionsProvider {
    struct Unavailable: Error {}
    var route: DirectionsRoute?
    var street: String?
    private(set) var streetLookups = 0
    private(set) var routeRequests = 0

    /// Every request's destination, in order.
    private(set) var destinations: [CLLocationCoordinate2D] = []

    func cyclingRoutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                       alternatives: Bool) async throws -> [DirectionsRoute] {
        routeRequests += 1
        destinations.append(to)
        guard let route else { throw Unavailable() }
        return [route]
    }

    func streetName(near: CLLocationCoordinate2D) async throws -> String? {
        streetLookups += 1
        guard let street else { throw Unavailable() }
        return street
    }
}

@Suite struct StreetNameTests {
    /// North 300 m, then right (east) for 400 m.
    private let line = Polyline(points([(0, 0), (300, 0), (300, 400)]))!
    private var turns: [Turn] { TurnDetector.turns(in: line) }

    @Test func usesApplesNameWhenItsRouteIsOurs() async {
        let fake = FakeDirections()
        fake.route = DirectionsRoute(
            coordinates: points([(260, 0), (300, 0), (300, 380)]),
            steps: [DirectionsStep(instructions: "", coordinates: points([(260, 0), (300, 0)])),
                    DirectionsStep(instructions: "Turn right onto Main St", coordinates: points([(300, 0), (300, 380)]))]
        )
        fake.street = "Wrong St"
        #expect(turns.map(\.direction) == [.right])
        #expect(await StreetNames.name(forTurn: 0, of: turns, on: line, using: fake) == .found("Main St"))
        #expect(fake.streetLookups == 0)
    }

    @Test func fallsBackWhenAppleTakesADifferentRoad() async {
        let fake = FakeDirections()
        // Apple goes a block further north before turning: not our road.
        fake.route = DirectionsRoute(
            coordinates: points([(260, 0), (400, 0), (400, 380), (300, 380)]),
            steps: [DirectionsStep(instructions: "Turn right onto Elm St", coordinates: points([(400, 0), (400, 380)]))]
        )
        fake.street = "Oak Ave"
        #expect(await StreetNames.name(forTurn: 0, of: turns, on: line, using: fake) == .found("Oak Ave"))
    }

    @Test func unreachableIsNotTheSameAsNoName() async {
        // Offline: worth asking again next time.
        #expect(await StreetNames.name(forTurn: 0, of: turns, on: line, using: FakeDirections()) == .failed)

        // Apple answered, with nothing usable.
        let fake = FakeDirections()
        fake.route = DirectionsRoute(coordinates: points([(260, 0), (300, 0), (300, 380)]), steps: [])
        #expect(await StreetNames.name(forTurn: 0, of: turns, on: line, using: fake) == .notFound)
    }

    @Test func streetFromAnAddress() {
        #expect(MapKitDirections.street(from: "1 Infinite Loop, Cupertino, CA") == "Infinite Loop")
        #expect(MapKitDirections.street(from: "10250-A N De Anza Blvd, Cupertino") == "N De Anza Blvd")
        #expect(MapKitDirections.street(from: "Stevens Creek Trail") == "Stevens Creek Trail")
        #expect(MapKitDirections.street(from: nil) == nil)
    }
}

@Suite struct GuidanceLegTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func leg() -> GuidanceLeg {
        GuidanceLeg(purpose: .toStart, route: DirectionsRoute(
            coordinates: points([(0, 0), (300, 0), (300, 400)]),
            steps: [DirectionsStep(instructions: "", coordinates: [at(0)]),
                    DirectionsStep(instructions: "Turn right onto Main St", coordinates: [at(300), at(300, 400)]),
                    DirectionsStep(instructions: "Arrive at the destination", coordinates: [at(300, 400)])]
        ))!
    }

    @Test func countsDownToTheNextStep() throws {
        var leg = leg()
        let kept = leg.update(at(100, 2), at: t0)
        #expect(kept)
        let next = try #require(leg.nextStep)
        #expect(next.instructions == "Turn right onto Main St")
        #expect(abs(next.distance - 200) < 1)

        let stillKept = leg.update(at(300, 100), at: t0 + 20)
        #expect(stillKept)
        #expect(leg.nextStep?.instructions == "Arrive at the destination")
        #expect(abs(leg.remaining - 300) < 1)
    }

    @Test func strayingForTwentySecondsAsksForANewLeg() {
        var leg = leg()
        let kept = [0.0, 19, 20].map { leg.update(at(100, 100), at: t0 + $0) }
        #expect(kept == [true, true, false])
    }
}
