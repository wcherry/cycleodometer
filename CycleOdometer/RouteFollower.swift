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
    let coordinates: [CLLocationCoordinate2D]
    /// Length of `coordinates`, in metres.
    let length: Double

    private(set) var hasJoined = false
    /// Distance along the route to your matched position, in metres.
    private(set) var progress = 0.0
    private(set) var isOffRoute = false
    private(set) var isFinished = false
    /// How far you are from the route (to the match used), in metres.
    private(set) var distanceFromRoute: Double?
    /// Degrees clockwise from north from you to that nearest point of the route.
    private(set) var bearingToRoute: Double?

    private let xy: [SIMD2<Double>]
    private let cumulative: [Double]
    private let origin: CLLocationCoordinate2D
    private let metersPerDegreeLongitude: Double
    private static let metersPerDegreeLatitude = 110_540.0

    private var farSince: Date?
    private var offSince: Date?

    init?(track: Track) {
        var points: [CLLocationCoordinate2D] = []
        for point in track.drawableSegments.joined() where points.last.map({
            $0.latitude != point.latitude || $0.longitude != point.longitude
        }) ?? true {
            points.append(point.coordinate)
        }
        guard points.count >= 2 else { return nil }
        coordinates = points
        origin = points[0]
        metersPerDegreeLongitude = 111_320 * cos(origin.latitude * .pi / 180)

        let xy = points.map {
            SIMD2(($0.longitude - points[0].longitude) * 111_320 * cos(points[0].latitude * .pi / 180),
                  ($0.latitude - points[0].latitude) * Self.metersPerDegreeLatitude)
        }
        var cumulative = [0.0]
        for i in 1..<xy.count {
            cumulative.append(cumulative[i - 1] + Self.length(xy[i] - xy[i - 1]))
        }
        self.xy = xy
        self.cumulative = cumulative
        length = cumulative.last ?? 0
    }

    /// The part of the route already ridden, for drawing.
    var doneCoordinates: [CLLocationCoordinate2D] {
        guard hasJoined, progress > 0 else { return [] }
        var done: [CLLocationCoordinate2D] = []
        for i in coordinates.indices {
            if cumulative[i] <= progress {
                done.append(coordinates[i])
            } else {
                let t = (progress - cumulative[i - 1]) / (cumulative[i] - cumulative[i - 1])
                done.append(coordinate(xy[i - 1] + t * (xy[i] - xy[i - 1])))
                break
            }
        }
        return done
    }

    var remaining: Double { max(length - progress, 0) }

    /// Matches a GPS fix to the route. Returns what changed, if anything.
    mutating func update(_ position: CLLocationCoordinate2D, accuracy: Double, at time: Date) -> Event? {
        let p = project(position)
        let offDistance = max(Self.offRouteDistance, 2 * accuracy)

        guard hasJoined else {
            // Progress starts wherever you first reach the route, preferring the
            // earliest point: at the start of a loop, the finish is just as close.
            let match = bestMatch(for: p, in: 0..<(xy.count - 1), preferAlong: 0)
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
                let anywhere = bestMatch(for: p, in: 0..<(xy.count - 1), preferAlong: progress)
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
                offSince = nil
                event = .rejoined
            }
        } else if match.distance > offDistance {
            let since = offSince ?? time
            offSince = since
            if time.timeIntervalSince(since) > Self.offRouteDelay {
                isOffRoute = true
                event = .leftRoute
            }
        } else {
            offSince = nil
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
        let first = cumulative.firstIndex { $0 >= low }.map { max($0 - 1, 0) } ?? 0
        let last = cumulative.firstIndex { $0 > high } ?? (xy.count - 1)
        return first..<max(last, first + 1)
    }

    private func bestMatch(for p: SIMD2<Double>, in segments: Range<Int>, preferAlong target: Double) -> Match {
        var matches: [(segment: Int, match: Match)] = []
        for i in segments {
            let a = xy[i], b = xy[i + 1], ab = b - a
            let lengthSquared = (ab * ab).sum()
            let t = lengthSquared > 0 ? min(max(((p - a) * ab).sum() / lengthSquared, 0), 1) : 0
            let point = a + t * ab
            matches.append((i, Match(distance: Self.length(p - point),
                                     along: cumulative[i] + t * (cumulative[i + 1] - cumulative[i]),
                                     point: point)))
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
        let delta = match.point - p
        bearingToRoute = (atan2(delta.x, delta.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private func project(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((c.longitude - origin.longitude) * metersPerDegreeLongitude,
              (c.latitude - origin.latitude) * Self.metersPerDegreeLatitude)
    }

    private func coordinate(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / Self.metersPerDegreeLatitude,
                               longitude: origin.longitude + p.x / metersPerDegreeLongitude)
    }

    private static func length(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }
}
