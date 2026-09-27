import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

private let lat0 = 37.33, lon0 = -122.03

/// A coordinate `north` / `east` metres from a spot in Cupertino.
private func at(_ north: Double, _ east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat0 + north / 110_540,
                           longitude: lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
}

/// A route through the given (north, east) corners, with a point every 10 m.
private func route(_ corners: [(Double, Double)]) -> RouteFollower {
    var points: [TrackPoint] = []
    for (a, b) in zip(corners, corners.dropFirst()) {
        let steps = max(Int((hypot(b.0 - a.0, b.1 - a.1) / 10).rounded()), 1)
        for i in 0..<steps {
            let t = Double(i) / Double(steps)
            let c = at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
            points.append(TrackPoint(latitude: c.latitude, longitude: c.longitude))
        }
    }
    let end = at(corners.last!.0, corners.last!.1)
    points.append(TrackPoint(latitude: end.latitude, longitude: end.longitude))
    return RouteFollower(track: Track(segments: [points]))!
}

/// Rides `follower` through `positions`, one fix per second from `start`.
@discardableResult
private func ride(_ follower: inout RouteFollower, _ positions: [CLLocationCoordinate2D],
                  from start: Date, accuracy: Double = 5) -> [RouteFollower.Event] {
    positions.enumerated().compactMap { i, p in
        follower.update(p, accuracy: accuracy, at: start + Double(i))
    }
}

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

@Suite struct RouteFollowerTests {
    @Test func progressAlongAStraightRoute() {
        var f = route([(0, 0), (1000, 0)])
        #expect(abs(f.length - 1000) < 1)
        let events = ride(&f, stride(from: 0.0, through: 500, by: 10).map { at($0, 3) }, from: t0)
        #expect(events == [.joined])
        #expect(abs(f.progress - 500) < 1)
        #expect(abs(f.remaining - 500) < 1)
        #expect(!f.isOffRoute)
        #expect(f.doneCoordinates.count > 2)
    }

    @Test func joinsOnlyOnceNearTheRoute() {
        var f = route([(0, 0), (1000, 0)])
        #expect(f.update(at(0, 200), accuracy: 5, at: t0) == nil)
        #expect(!f.hasJoined)
        #expect(abs((f.distanceFromRoute ?? 0) - 200) < 1)
        // Due west of you: the route is at 270°.
        #expect(abs((f.bearingToRoute ?? 0) - 270) < 1)
        #expect(f.update(at(300, 10), accuracy: 5, at: t0 + 1) == .joined)
        #expect(abs(f.progress - 300) < 1)
    }

    @Test func aLoopDoesNotFinishAtTheStart() {
        let loop = [(0.0, 0.0), (500, 0), (500, 500), (0, 500), (0, 0)]
        var f = route(loop)
        #expect(f.update(at(0, 0), accuracy: 5, at: t0) == .joined)
        #expect(f.progress < 5)
        #expect(!f.isFinished)

        var positions: [CLLocationCoordinate2D] = []
        for (a, b) in zip(loop, loop.dropFirst()) {
            for i in 1...50 {
                let t = Double(i) / 50
                positions.append(at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
            }
        }
        let events = ride(&f, positions, from: t0 + 1)
        #expect(events == [.finished])
        #expect(f.isFinished)
    }

    @Test func outAndBackDoesNotJumpAtTheTurnaround() {
        var f = route([(0, 0), (1000, 0), (0, 0)])
        // Out to 800 m: the way back passes the same spots, only 400 m further on.
        ride(&f, stride(from: 0.0, through: 800, by: 10).map { at($0) }, from: t0)
        #expect(abs(f.progress - 800) < 1)
        // Up to the turnaround and back to 900 m on the return leg.
        ride(&f, stride(from: 810.0, through: 1000, by: 10).map { at($0) }, from: t0 + 100)
        ride(&f, stride(from: 990.0, through: 900, by: -10).map { at($0) }, from: t0 + 200)
        #expect(abs(f.progress - 1100) < 2)
    }

    @Test func figureEightCrossingKeepsTheCurrentPass() {
        // Crosses itself at (500, 500): once at 707 m along, again at about 2121 m.
        var f = route([(0, 0), (1000, 1000), (1000, 0), (0, 1000)])
        ride(&f, stride(from: 0.0, through: 1000, by: 10).map { at($0, $0) }, from: t0)
        ride(&f, stride(from: 990.0, through: 0, by: -10).map { at(1000, $0) }, from: t0 + 200)
        ride(&f, stride(from: 10.0, through: 490, by: 10).map { at(1000 - $0, $0) }, from: t0 + 400)
        let before = f.progress
        ride(&f, [at(500, 500), at(490, 510)], from: t0 + 500)
        #expect(f.progress > before)
        #expect(f.progress > 2000)
    }

    @Test func offRouteAfterTenSecondsAndBackWithAGap() {
        var f = route([(0, 0), (2000, 0)])
        ride(&f, stride(from: 0.0, through: 200, by: 10).map { at($0) }, from: t0)

        // 80 m off: not yet an alert...
        let away = ride(&f, (0..<10).map { _ in at(200, 80) }, from: t0 + 100)
        #expect(away.isEmpty)
        #expect(!f.isOffRoute)
        // ...until it's lasted more than 10 s.
        #expect(ride(&f, [at(200, 80), at(200, 80)], from: t0 + 110) == [.leftRoute])
        #expect(f.isOffRoute)

        // 40 m is inside the off-route distance but not yet back on.
        #expect(ride(&f, [at(200, 40)], from: t0 + 120).isEmpty)
        #expect(f.isOffRoute)
        #expect(ride(&f, [at(200, 20)], from: t0 + 121) == [.rejoined])
        #expect(!f.isOffRoute)
    }

    @Test func poorAccuracyWidensTheOffRouteDistance() {
        var f = route([(0, 0), (2000, 0)])
        ride(&f, [at(0), at(10)], from: t0)
        // 70 m off with 40 m accuracy is within 2 × accuracy: not off route.
        ride(&f, (0..<20).map { _ in at(10, 70) }, from: t0 + 10, accuracy: 40)
        #expect(!f.isOffRoute)
    }

    @Test func recoversAfterAShortcut() {
        // A U-shaped route; the rider cuts straight across the bottom of the U.
        var f = route([(2000, 0), (0, 0), (0, 400), (2000, 400)])
        ride(&f, stride(from: 2000.0, through: 1500, by: -10).map { at($0) }, from: t0)
        #expect(abs(f.progress - 500) < 1)
        // Across the gap: well away from the route for over 30 s.
        ride(&f, stride(from: 0.0, through: 400, by: 10).map { at(1500, $0 < 400 ? $0 : 400) }, from: t0 + 100)
        ride(&f, (0..<5).map { _ in at(1500, 400) }, from: t0 + 150)
        // Picked up 1500 m up the far side of the U: 2000 + 400 + 1500 m along.
        #expect(abs(f.progress - 3900) < 15)
        #expect(!f.isOffRoute)
    }
}
