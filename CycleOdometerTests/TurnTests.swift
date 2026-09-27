import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

private let lat0 = 37.33, lon0 = -122.03

private func at(_ north: Double, _ east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: lat0 + north / 110_540,
                           longitude: lon0 + east / (111_320 * cos(lat0 * .pi / 180)))
}

/// A line through (north, east) corners, a point every 5 m, with optional sideways wobble.
private func line(_ corners: [(Double, Double)], wobble: Double = 0) -> Polyline {
    var points: [CLLocationCoordinate2D] = []
    var n = 0
    for (a, b) in zip(corners, corners.dropFirst()) {
        let steps = max(Int((hypot(b.0 - a.0, b.1 - a.1) / 5).rounded()), 1)
        for i in 0..<steps {
            let t = Double(i) / Double(steps)
            let jitter = wobble * (n.isMultiple(of: 2) ? 1 : -1)
            n += 1
            points.append(at(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t + jitter))
        }
    }
    points.append(at(corners.last!.0, corners.last!.1))
    return Polyline(points)!
}

@Suite struct TurnDetectorTests {
    @Test func gridStreets() {
        // North 300 m, right (east) 200 m, left (north) 300 m, left (west) 100 m.
        let turns = TurnDetector.turns(in: line([(0, 0), (300, 0), (300, 200), (600, 200), (600, 100)]))
        #expect(turns.map(\.direction) == [.right, .left, .left])
        #expect(turns.map { Int($0.along.rounded()) } == [300, 500, 800])
    }

    @Test func gpsWobbleOnAStraightRoadIsNotATurn() {
        #expect(TurnDetector.turns(in: line([(0, 0), (1000, 0)], wobble: 3)).isEmpty)
    }

    @Test func slightAndSharpTurns() {
        // A 45° bear right, then a 135° sharp left.
        let turns = TurnDetector.turns(in: line([(0, 0), (300, 0), (512, 212), (512, -88)]))
        #expect(turns.map(\.direction) == [.slightRight, .sharpLeft])
    }

    @Test func outAndBackTurnaroundIsAUTurn() {
        let turns = TurnDetector.turns(in: line([(0, 0), (500, 0), (0, 0)]))
        #expect(turns.map(\.direction) == [.uTurn])
    }

    @Test func aRoadJogIsOneCue() {
        // Right, then left 24 m later, back onto the same heading. (A jog much under
        // 20 m sideways is within the 10 m simplification and isn't a turn at all.)
        let turns = TurnDetector.turns(in: line([(0, 0), (300, 0), (300, 24), (600, 24)]))
        #expect(turns.count == 1)
        #expect(turns.first?.direction == .right)
    }

    @Test func headingChange() {
        #expect(TurnDetector.change(from: 350, to: 10) == 20)
        #expect(TurnDetector.change(from: 10, to: 350) == -20)
        #expect(TurnDetector.change(from: 0, to: 180) == 180)
    }
}

@Suite struct DirectionTextTests {
    @Test func streetNames() {
        #expect(DirectionText.streetName(in: "Turn right onto Main St") == "Main St")
        #expect(DirectionText.streetName(in: "Continue on Stevens Creek Blvd") == "Stevens Creek Blvd")
        #expect(DirectionText.streetName(in: "Keep left toward Bike Path.") == "Bike Path")
        #expect(DirectionText.streetName(in: "Arrive at the destination") == nil)
        #expect(DirectionText.streetName(in: "Turn left") == nil)
    }

    @Test func symbols() {
        #expect(DirectionText.symbol(for: "Turn left onto Oak Ave") == "arrow.turn.up.left")
        #expect(DirectionText.symbol(for: "Slight right onto Elm St") == "arrow.up.right")
        #expect(DirectionText.symbol(for: "Make a U-turn") == "arrow.uturn.down")
        #expect(DirectionText.symbol(for: "Arrive at your destination") == "flag.checkered")
    }
}
