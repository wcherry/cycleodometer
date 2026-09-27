import CoreLocation
import Foundation

/// Follows a route: matches each GPS fix to a point along it, measures progress, and
/// decides when the rider has left the route or come back to it.
///
/// Pure logic with the time passed in, so it can be tested without GPS.
/// The thresholds are the ones in docs/features/routes-and-maps.md.
struct RouteFollower {
    enum Event: Equatable {
        /// First reached the route (at the start, or wherever you joined it).
        case joined
        case leftRoute
        case rejoined
        /// Within `finishDistance` of the end.
        case finished
    }

    /// Off route once further than this (or twice the GPS accuracy, if worse)...
    static let offRouteDistance = 50.0
    /// ...for longer than this...
    static let offRouteDelay: TimeInterval = 10
    /// ...and back on route only once closer than this. The gap stops it flickering.
    static let backOnDistance = 30.0
    /// Matching looks this far ahead of your progress, and a little behind, so a
    /// route that crosses or retraces itself doesn't jump to the wrong pass.
    static let windowAhead = 1_000.0
    static let windowBehind = 100.0
    /// After this long with no match near your progress (a shortcut, a detour),
    /// matching searches the whole route.
    static let recoveryDelay: TimeInterval = 30
    /// Where a route passes the same spot more than once (a loop's start and finish,
    /// an out-and-back, a figure-eight), passes this close to the best are treated as
    /// a tie, and the one nearest your progress wins.
    static let tieMargin = 10.0
    static let finishDistance = 30.0

    /// The route as one line, in order.
    let line: Polyline
    var coordinates: [CLLocationCoordinate2D] { line.coordinates }
    /// Length of the route, in metres.
    var length: Double { line.length }

    private(set) var hasJoined = false
    /// Distance along the route to your matched position, in metres.
    private(set) var progress = 0.0
    private(set) var isOffRoute = false
    private(set) var isFinished = false
    /// How far you are from the route (to the match used), in metres.
    private(set) var distanceFromRoute: Double?
    /// Degrees clockwise from north from you to that nearest point of the route.
    private(set) var bearingToRoute: Double?

    /// When the current spell off route began (off route or not yet declared so).
    private(set) var offRouteSince: Date?

    private var farSince: Date?

    init?(track: Track) {
        guard let line = Polyline(track.drawableSegments.joined().map(\.coordinate)) else { return nil }
        self.line = line
    }

    /// The part of the route already ridden, for drawing.
    var doneCoordinates: [CLLocationCoordinate2D] {
        hasJoined ? line.coordinates(upTo: progress) : []
    }

    var remaining: Double { max(length - progress, 0) }

    /// Matches a GPS fix to the route. Returns what changed, if anything.
    mutating func update(_ position: CLLocationCoordinate2D, accuracy: Double, at time: Date) -> Event? {
        let p = line.project(position)
        let offDistance = max(Self.offRouteDistance, 2 * accuracy)

        guard hasJoined else {
            // Progress starts wherever you first reach the route, preferring the
            // earliest point: at the start of a loop, the finish is just as close.
            let match = bestMatch(for: p, in: 0..<line.segmentCount, preferAlong: 0)
            record(match, from: p)
            guard match.distance <= Self.backOnDistance else { return nil }
            hasJoined = true
            progress = match.along
            return .joined
        }

        let window = bestMatch(for: p, in: windowSegments(), preferAlong: progress)
        var match = window
        if window.distance <= offDistance {
            farSince = nil
            progress = window.along
        } else {
            let since = farSince ?? time
            farSince = since
            if time.timeIntervalSince(since) >= Self.recoveryDelay {
                let anywhere = bestMatch(for: p, in: 0..<line.segmentCount, preferAlong: progress)
                if anywhere.distance < match.distance { match = anywhere }
                if anywhere.distance <= Self.backOnDistance {
                    farSince = nil
                    progress = anywhere.along
                }
            }
        }
        record(match, from: p)

        var event: Event?
        if isOffRoute {
            if match.distance < Self.backOnDistance {
                isOffRoute = false
                offRouteSince = nil
                event = .rejoined
            }
        } else if match.distance > offDistance {
            let since = offRouteSince ?? time
            offRouteSince = since
            if time.timeIntervalSince(since) > Self.offRouteDelay {
                isOffRoute = true
                event = .leftRoute
            }
        } else {
            offRouteSince = nil
        }

        if !isFinished, !isOffRoute, length - progress <= Self.finishDistance {
            isFinished = true
            event = event ?? .finished
        }
        return event
    }

    // MARK: Geometry

    private struct Match {
        var distance: Double
        var along: Double
        var point: SIMD2<Double>
    }

    private func windowSegments() -> Range<Int> {
        let low = progress - Self.windowBehind, high = progress + Self.windowAhead
        let first = line.cumulative.firstIndex { $0 >= low }.map { max($0 - 1, 0) } ?? 0
        let last = line.cumulative.firstIndex { $0 > high } ?? line.segmentCount
        return first..<max(last, first + 1)
    }

    private func bestMatch(for p: SIMD2<Double>, in segments: Range<Int>, preferAlong target: Double) -> Match {
        let matches = segments.map { i in
            let projected = line.projection(of: p, ontoSegment: i)
            return (segment: i, match: Match(distance: projected.distance, along: projected.along, point: projected.point))
        }
        let closest = matches.map(\.match.distance).min() ?? .infinity

        // One candidate per pass: a run of neighbouring segments within the margin is
        // the same stretch of road, represented by its closest point. Without this,
        // the segment just behind you would always tie with the one you're on.
        // Points within a metre of each other are equally close; there, and between
        // passes, the one that fits your progress best wins.
        func cost(_ match: Match) -> Double {
            // Riders move forward along a route, so going backwards costs more. At an
            // out-and-back's turnaround the two passes meet end to end, and this is
            // what carries you onto the return leg instead of back down the way out.
            match.along >= target ? match.along - target : (target - match.along) * 4
        }
        var passes: [Match] = []
        var previous: Int?
        for (segment, match) in matches where match.distance <= closest + Self.tieMargin {
            if let previous, segment == previous + 1, let last = passes.last {
                let closer = match.distance < last.distance - 1
                let asClose = abs(match.distance - last.distance) <= 1
                if closer || (asClose && cost(match) < cost(last)) {
                    passes[passes.count - 1] = match
                }
            } else {
                passes.append(match)
            }
            previous = segment
        }
        return passes.min { cost($0) < cost($1) }!
    }

    private mutating func record(_ match: Match, from p: SIMD2<Double>) {
        distanceFromRoute = match.distance
        bearingToRoute = Polyline.bearing(from: p, to: match.point)
    }
}
