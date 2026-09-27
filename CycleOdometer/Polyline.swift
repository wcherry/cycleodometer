import CoreLocation
import Foundation

/// A line through coordinates, with the flat-earth geometry route following needs:
/// positions in metres, distance along the line, and projecting onto it.
///
/// Projected around the first point, which is plenty accurate over a ride.
struct Polyline {
    let coordinates: [CLLocationCoordinate2D]
    /// Each coordinate in metres east (x) and north (y) of the first.
    let xy: [SIMD2<Double>]
    /// Distance along the line to each coordinate, in metres.
    let cumulative: [Double]

    private let origin: CLLocationCoordinate2D
    private let metersPerDegreeLongitude: Double
    private static let metersPerDegreeLatitude = 110_540.0

    /// Nil unless there are at least two distinct points. Repeated points are dropped.
    init?(_ coordinates: [CLLocationCoordinate2D]) {
        var points: [CLLocationCoordinate2D] = []
        for c in coordinates where points.last.map({ $0.latitude != c.latitude || $0.longitude != c.longitude }) ?? true {
            points.append(c)
        }
        guard points.count >= 2 else { return nil }
        self.coordinates = points
        origin = points[0]
        metersPerDegreeLongitude = 111_320 * cos(points[0].latitude * .pi / 180)

        let origin = points[0], perLongitude = metersPerDegreeLongitude
        let xy = points.map {
            SIMD2(($0.longitude - origin.longitude) * perLongitude,
                  ($0.latitude - origin.latitude) * Self.metersPerDegreeLatitude)
        }
        var cumulative = [0.0]
        for i in 1..<xy.count {
            cumulative.append(cumulative[i - 1] + Self.length(xy[i] - xy[i - 1]))
        }
        self.xy = xy
        self.cumulative = cumulative
    }

    var length: Double { cumulative.last ?? 0 }

    var segmentCount: Int { xy.count - 1 }

    func project(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((c.longitude - origin.longitude) * metersPerDegreeLongitude,
              (c.latitude - origin.latitude) * Self.metersPerDegreeLatitude)
    }

    func coordinate(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / Self.metersPerDegreeLatitude,
                               longitude: origin.longitude + p.x / metersPerDegreeLongitude)
    }

    /// The point `distance` metres along the line, clamped to its ends.
    func point(at distance: Double) -> SIMD2<Double> {
        let d = min(max(distance, 0), length)
        guard let i = cumulative.firstIndex(where: { $0 >= d }), i > 0 else { return xy[0] }
        let span = cumulative[i] - cumulative[i - 1]
        let t = span > 0 ? (d - cumulative[i - 1]) / span : 0
        return xy[i - 1] + t * (xy[i] - xy[i - 1])
    }

    /// The line from its start to `distance` metres along, for drawing.
    func coordinates(upTo distance: Double) -> [CLLocationCoordinate2D] {
        guard distance > 0 else { return [] }
        var result: [CLLocationCoordinate2D] = []
        for i in coordinates.indices {
            if cumulative[i] <= distance {
                result.append(coordinates[i])
            } else {
                result.append(coordinate(point(at: distance)))
                break
            }
        }
        return result
    }

    /// Where `p` projects onto segment `i`: the closest point, how far from `p` it is,
    /// and its distance along the line.
    func projection(of p: SIMD2<Double>, ontoSegment i: Int) -> (point: SIMD2<Double>, distance: Double, along: Double) {
        let a = xy[i], b = xy[i + 1], ab = b - a
        let lengthSquared = (ab * ab).sum()
        let t = lengthSquared > 0 ? min(max(((p - a) * ab).sum() / lengthSquared, 0), 1) : 0
        let point = a + t * ab
        return (point, Self.length(p - point), cumulative[i] + t * (cumulative[i + 1] - cumulative[i]))
    }

    /// The closest point on the whole line to `c`.
    func nearest(to c: CLLocationCoordinate2D) -> (point: SIMD2<Double>, distance: Double, along: Double) {
        let p = project(c)
        return (0..<segmentCount).map { projection(of: p, ontoSegment: $0) }.min { $0.distance < $1.distance }!
    }

    /// Degrees clockwise from north, from `a` to `b`.
    static func bearing(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Double {
        let d = b - a
        return (atan2(d.x, d.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func length(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }
}
