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

/// Rides the tracker through positions, `offset` seconds from now each (the tracker
/// ignores fixes more than 10 s old or ahead).
private func feed(_ ride: RideTracker, _ positions: [(CLLocationCoordinate2D, TimeInterval)]) {
    for (p, offset) in positions {
        ride.locationManager(CLLocationManager(), didUpdateLocations: [
            CLLocation(coordinate: p, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       course: 0, speed: 6, timestamp: .now + offset),
        ])
    }
}

private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

/// Apple's route: north 300 m, right onto Main St for 400 m, arrive.
private let directions = DirectionsRoute(
    coordinates: points([(0, 0), (300, 0), (300, 400)]),
    steps: [DirectionsStep(instructions: "", coordinates: [at(0)]),
            DirectionsStep(instructions: "Turn right onto Main St", coordinates: [at(300), at(300, 400)]),
            DirectionsStep(instructions: "Arrive at the destination", coordinates: [at(300, 400)])],
    distance: 700, expectedTravelTime: 140, name: "Main St"
)
private let cafe = Destination(name: "Café", subtitle: "1 Main St", coordinate: at(300, 400))

@MainActor
@Suite(.serialized) struct NavigationTests {
    private func ride(_ fake: FakeDirections = FakeDirections()) -> RideTracker {
        let ride = RideTracker()
        ride.directions = fake
        ride.liveActivity = nil
        return ride
    }

    private func text(_ ride: RideTracker) throws -> RouteStatusText {
        let follower = try #require(ride.follower)
        return RouteStatusText(status: RouteStatus(follower: follower, recentlyRejoined: false, cue: ride.currentCue),
                               follower: follower, routeName: ride.routeName, units: .imperial, navigation: ride.navigation)
    }

    @Test func cuesApplesStepsWithTimeLeft() throws {
        let ride = ride()
        ride.startNavigation(to: cafe, along: directions)
        defer { ride.end() }
        #expect(ride.routeName == "Café")

        feed(ride, stride(from: 0.0, through: 200, by: 10).map { (at($0), 0) })
        let cue = try #require(ride.currentCue)
        #expect(cue.kind == .step(0))
        #expect(cue.instruction == "Turn right onto Main St")
        #expect(abs(cue.distance - 100) < 2)
        // 500 of 700 m left: 5/7 of Apple's 140 s.
        #expect(try text(ride).detail == "In 330 ft · 2 min left")
    }

    @Test func arrives() throws {
        let ride = ride()
        ride.startNavigation(to: cafe, along: directions)
        defer { ride.end() }

        feed(ride, points([(0, 0), (300, 0), (300, 400)]).map { ($0, 0) })
        #expect(ride.follower?.isFinished == true)
        let words = try text(ride)
        #expect(words.title == "Arrived")
        #expect(words.detail == "1 Main St")
        // Still recording: arriving doesn't end the ride.
        #expect(ride.isActive)
    }

    @Test func goingOffRoutePlansANewRoute() async throws {
        let fake = FakeDirections()
        // From where the rider strays (100 m north, 200 m east) to the café.
        fake.route = DirectionsRoute(coordinates: points([(100, 200), (300, 200), (300, 400)]),
                                     steps: [], distance: 400, expectedTravelTime: 80)
        let ride = ride(fake)
        ride.startNavigation(to: cafe, along: directions)
        defer { ride.end() }

        feed(ride, [(at(0), -9), (at(50), -8), (at(100), -7)])
        // Over 10 s well away from the route: off route, so a new route is requested.
        feed(ride, (0...15).map { (at(100, 200), -6 + Double($0)) })

        #expect(await eventually { fake.routeRequests == 1 && ride.follower?.isOffRoute == false })
        let destination = try #require(fake.destinations.last)
        #expect(abs(destination.latitude - cafe.latitude) < 1e-9)
        #expect(abs((ride.follower?.length ?? 0) - 400) < 2)
        #expect(ride.navigation?.expectedTravelTime == 80)
    }
}

@Suite struct RecentDestinationTests {
    private let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")

    @Test func newestFirstWithoutRepeats() {
        let recents = RecentDestinations(fileURL: file)
        recents.add(Destination(name: "A", coordinate: at(0)))
        recents.add(Destination(name: "B", coordinate: at(1000)))
        // The same place again (20 m away): moves to the top instead of repeating.
        recents.add(Destination(name: "A again", coordinate: at(20)))
        #expect(recents.items.map(\.name) == ["A again", "B"])
    }

    @Test func keepsTheLastTenAndSurvivesARelaunch() {
        let recents = RecentDestinations(fileURL: file)
        for i in 0..<12 {
            recents.add(Destination(name: "\(i)", coordinate: at(Double(i) * 1000)))
        }
        #expect(recents.items.count == RecentDestinations.limit)
        #expect(recents.items.first?.name == "11")
        #expect(RecentDestinations(fileURL: file).items.map(\.name) == recents.items.map(\.name))

        recents.clear()
        #expect(RecentDestinations(fileURL: file).items.isEmpty)
    }

    @Test func timeLeftWording() {
        #expect(Navigation.timeLeftText(20) == "Under 1 min left")
        #expect(Navigation.timeLeftText(12 * 60) == "12 min left")
        #expect(Navigation.timeLeftText(65 * 60) == "1 h 5 min left")
        #expect(Navigation.timeLeftText(120 * 60) == "2 h left")
    }
}
