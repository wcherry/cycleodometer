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

/// A GPS fix as the location manager would deliver it: fresh and accurate.
private func fix(_ c: CLLocationCoordinate2D) -> CLLocation {
    CLLocation(coordinate: c, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
               course: 0, speed: 6, timestamp: .now)
}

/// Rides the tracker through positions by calling its location delegate directly.
private func feed(_ ride: RideTracker, _ positions: [CLLocationCoordinate2D]) {
    for p in positions {
        ride.locationManager(CLLocationManager(), didUpdateLocations: [fix(p)])
    }
}

/// Waits (briefly) for something the tracker does in the background.
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

/// North 300 m, right (east) 400 m: one right turn, at 300 m.
private let routeTrack = Track(segments: [points([(0, 0), (300, 0), (300, 400)]).map {
    TrackPoint(latitude: $0.latitude, longitude: $0.longitude)
}])

@MainActor
@Suite(.serialized) struct GuidanceTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func setUp(_ fake: FakeDirections) -> (RideTracker, RouteLibrary, SavedRoute) {
        let library = RouteLibrary(directory: directory)
        let route = library.add(name: "Test", track: routeTrack, source: .imported)!
        let ride = RideTracker()
        ride.directions = fake
        ride.liveActivity = nil
        ride.voice = nil
        return (ride, library, route)
    }

    @Test func cuesTheNextTurnWithItsStreet() async throws {
        let fake = FakeDirections()
        fake.route = DirectionsRoute(
            coordinates: points([(260, 0), (300, 0), (300, 380)]),
            steps: [DirectionsStep(instructions: "Turn right onto Main St", coordinates: points([(300, 0), (300, 380)]))]
        )
        let (ride, library, route) = setUp(fake)
        ride.start(following: route, track: await library.loadTrack(for: route), library: library)
        defer { ride.end() }

        feed(ride, stride(from: 0.0, through: 200, by: 10).map { at($0) })
        let cue = try #require(ride.currentCue)
        #expect(cue.kind == .turn(0))
        #expect(cue.instruction == "Right")
        #expect(abs(cue.distance - 100) < 2)
        #expect(cue.stage == 1)

        // The street is looked up in the background, and saved to the route.
        #expect(await eventually { ride.turns.first?.streetName == "Main St" })
        #expect(library.routes.first?.turnNames == TurnNames(turnCount: 1, names: ["Main St"]))
    }

    @Test func savedNamesAreNotLookedUpAgain() async throws {
        let fake = FakeDirections()
        let (ride, library, route) = setUp(fake)
        library.saveTurnNames(TurnNames(turnCount: 1, names: ["Oak Ave"]), for: route)
        let named = try #require(library.routes.first)

        ride.start(following: named, track: await library.loadTrack(for: named), library: library)
        defer { ride.end() }
        #expect(ride.turns.first?.streetName == "Oak Ave")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(fake.routeRequests == 0)
    }

    @Test func ridesToTheStartUntilTheRouteIsReached() async throws {
        let fake = FakeDirections()
        // From 500 m south of the route: straight north to its start.
        fake.route = DirectionsRoute(
            coordinates: points([(-500, 0), (0, 0)]),
            steps: [DirectionsStep(instructions: "", coordinates: [at(-500)]),
                    DirectionsStep(instructions: "Arrive at the destination", coordinates: [at(0)])]
        )
        let (ride, library, route) = setUp(fake)
        ride.start(following: route, track: await library.loadTrack(for: route), library: library, rideToStart: true)
        defer { ride.end() }

        feed(ride, [at(-500)])
        #expect(await eventually { ride.approach != nil })
        feed(ride, [at(-400)])
        let cue = try #require(ride.currentCue)
        #expect(cue.kind == .leg(.toStart, step: 0))
        #expect(abs(cue.distance - 400) < 2)

        // Reaching the route ends the directions and brings back the route's turns.
        feed(ride, stride(from: -300.0, through: 100, by: 10).map { at($0) })
        #expect(ride.approach == nil)
        #expect(ride.currentCue?.kind == .turn(0))
    }
}
