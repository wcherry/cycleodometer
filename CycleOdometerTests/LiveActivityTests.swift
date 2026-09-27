import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

private func state(speed: Double = 10, paused: Bool = false) -> RideActivityAttributes.ContentState {
    RideActivityAttributes.ContentState(speed: speed, speedUnit: "mph", distance: 1, distanceUnit: "mi",
                                       elapsed: 60, timerStart: paused ? nil : Date(timeIntervalSince1970: 0))
}

@Suite struct LiveActivityThrottleTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func routineChangesWaitFiveSeconds() {
        var throttle = LiveActivityThrottle()
        let sent = [
            throttle.shouldSend(state(speed: 10), key: "a", at: t0),
            throttle.shouldSend(state(speed: 11), key: "a", at: t0 + 2),
            throttle.shouldSend(state(speed: 12), key: "a", at: t0 + 5),
        ]
        #expect(sent == [true, false, true])
    }

    @Test func urgentChangesGoStraightAway() {
        var throttle = LiveActivityThrottle()
        let sent = [
            throttle.shouldSend(state(), key: "running", at: t0),
            throttle.shouldSend(state(paused: true), key: "paused", at: t0 + 1),
        ]
        #expect(sent == [true, true])
    }

    @Test func nothingNewIsNotSent() {
        var throttle = LiveActivityThrottle()
        let sent = [
            throttle.shouldSend(state(), key: "a", at: t0),
            throttle.shouldSend(state(), key: "a", at: t0 + 60),
        ]
        #expect(sent == [true, false])
    }
}

private let lat0 = 37.33, lon0 = -122.03

private func at(_ north: Double, _ east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat0 + north / 110_540,
                           longitude: lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
}

@MainActor
@Suite struct LiveActivitySnapshotTests {
    @Test func showsTheNextTurnAndPauses() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let library = RouteLibrary(directory: directory)
        // North 300 m, then right (east) 400 m.
        let points = (0...30).map { at(Double($0) * 10) } + (1...40).map { at(300, Double($0) * 10) }
        let track = Track(segments: [points.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude) }])
        let route = try #require(library.add(name: "Test", track: track, source: .imported))

        let ride = RideTracker()
        ride.liveActivity = nil
        ride.voice = nil
        ride.directions = FakeDirections()
        UserDefaults.standard.set(false, forKey: StreetNameSetting.key)
        defer { UserDefaults.standard.removeObject(forKey: StreetNameSetting.key) }
        ride.start(following: route, track: await library.loadTrack(for: route), library: library)
        defer { ride.end() }

        for north in stride(from: 0.0, through: 200, by: 10) {
            ride.locationManager(CLLocationManager(), didUpdateLocations: [
                CLLocation(coordinate: at(north), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                           course: 0, speed: 6, timestamp: .now),
            ])
        }

        let running = ride.liveActivitySnapshot()
        #expect(running.state.speedUnit == "mph")
        #expect(abs(running.state.speed - 13.4) < 0.1)
        #expect(running.state.timerStart != nil)
        #expect(!running.state.isPaused)
        let line = try #require(running.state.route)
        #expect(line.title == "Right in 330 ft")
        #expect(!line.isWarning)

        ride.toggleTimer()
        let paused = ride.liveActivitySnapshot()
        #expect(paused.state.isPaused)
        #expect(paused.key != running.key)
    }
}
