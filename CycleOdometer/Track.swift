import CoreLocation
import Foundation

/// One recorded GPS point.
struct TrackPoint: Hashable {
    var latitude: Double
    var longitude: Double
    var time: Date?
    /// Metres above sea level, from GPS, when known.
    var elevation: Double?
    /// Metres per second, when known.
    var speed: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A ride's path: one segment per stretch of riding, split wherever the ride was
/// paused, so a map never draws a straight line across a stop.
struct Track: Hashable {
    var segments: [[TrackPoint]] = []

    /// Segments that can be drawn as a line (a single point can't).
    var drawableSegments: [[TrackPoint]] {
        segments.filter { $0.count >= 2 }
    }

    var isEmpty: Bool { drawableSegments.isEmpty }

    /// Length along the track in metres, not counting the gaps between segments.
    var distance: Double {
        drawableSegments.reduce(0) { total, segment in
            zip(segment, segment.dropFirst()).reduce(total) { sum, pair in
                sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
        }
    }

    /// Total climb in metres, or nil if the track has no elevations.
    ///
    /// GPS elevation wobbles by several metres, so a climb only counts once it's
    /// risen `threshold` metres above the lowest point since the last counted climb.
    func elevationGain(threshold: Double = 5) -> Double? {
        var gain = 0.0
        var sawElevation = false
        for segment in drawableSegments {
            var reference: Double?
            for elevation in segment.compactMap(\.elevation) {
                sawElevation = true
                guard let low = reference else {
                    reference = elevation
                    continue
                }
                if elevation > low + threshold {
                    gain += elevation - low
                    reference = elevation
                } else if elevation < low {
                    reference = elevation
                }
            }
        }
        return sawElevation ? gain : nil
    }
}

/// Builds a `Track` from location fixes during a ride.
struct TrackRecorder {
    /// A point is kept only once the rider has moved this far from the last one.
    /// Keeps a 100 km ride to roughly 20,000 points without losing its shape.
    static let minimumSpacing = 5.0

    private(set) var track = Track()
    private var startsNewSegment = true
    private var lastStored: CLLocation?

    mutating func reset() {
        track = Track()
        startsNewSegment = true
        lastStored = nil
    }

    /// Ends the current segment; the next point starts a new one. Called on pause.
    mutating func breakSegment() {
        startsNewSegment = true
        lastStored = nil
    }

    /// Adds the fix to the track if it's far enough from the last point.
    /// Returns whether it was stored.
    @discardableResult
    mutating func record(_ location: CLLocation) -> Bool {
        if let lastStored, location.distance(from: lastStored) < Self.minimumSpacing {
            return false
        }
        let point = TrackPoint(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            time: location.timestamp,
            elevation: location.verticalAccuracy > 0 ? location.altitude : nil,
            speed: location.speed >= 0 ? location.speed : nil
        )
        if startsNewSegment || track.segments.isEmpty {
            track.segments.append([point])
            startsNewSegment = false
        } else {
            track.segments[track.segments.count - 1].append(point)
        }
        lastStored = location
        return true
    }
}

enum Simplify {
    /// Douglas–Peucker: drops points that lie within `tolerance` metres of the line
    /// through their neighbours, keeping the shape (corners, curves) intact.
    static func coordinates(_ points: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        indices(of: points, tolerance: tolerance).map { points[$0] }
    }

    /// The same, for track points: keeps each survivor's elevation and other fields.
    static func points(_ points: [TrackPoint], tolerance: Double) -> [TrackPoint] {
        indices(of: points.map(\.coordinate), tolerance: tolerance).map { points[$0] }
    }

    /// Indices of the points Douglas–Peucker keeps, in order; always the first and last.
    static func indices(of points: [CLLocationCoordinate2D], tolerance: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }

        // Flat-earth projection around the first point: plenty accurate over a ride.
        let origin = points[0]
        let metersPerDegreeLatitude = 110_540.0
        let metersPerDegreeLongitude = 111_320.0 * cos(origin.latitude * .pi / 180)
        let xy = points.map {
            SIMD2(($0.longitude - origin.longitude) * metersPerDegreeLongitude,
                  ($0.latitude - origin.latitude) * metersPerDegreeLatitude)
        }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        // Iterative rather than recursive: a long straight road would otherwise
        // recurse once per point.
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var farthest = first
            var farthestDistance = 0.0
            for i in (first + 1)..<last {
                let d = distance(from: xy[i], toSegment: xy[first], xy[last])
                if d > farthestDistance {
                    farthestDistance = d
                    farthest = i
                }
            }
            if farthestDistance > tolerance {
                keep[farthest] = true
                stack.append((first, farthest))
                stack.append((farthest, last))
            }
        }
        return points.indices.filter { keep[$0] }
    }

    private static func distance(from p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        guard lengthSquared > 0 else { return ((p - a) * (p - a)).sum().squareRoot() }
        let t = min(max(((p - a) * ab).sum() / lengthSquared, 0), 1)
        let closest = a + t * ab
        return ((p - closest) * (p - closest)).sum().squareRoot()
    }
}
