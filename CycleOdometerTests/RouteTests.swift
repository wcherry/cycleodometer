import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

/// A point `north` / `east` metres from a spot in Cupertino.
private func point(north: Double = 0, east: Double = 0, elevation: Double? = nil,
                   time: Date? = nil, speed: Double? = nil) -> TrackPoint {
    let lat0 = 37.33, lon0 = -122.03
    return TrackPoint(latitude: lat0 + north / 110_540,
                      longitude: lon0 + east / (111_320 * cos(lat0 * .pi / 180)),
                      time: time, elevation: elevation, speed: speed)
}

@Suite struct TrackMeasurementTests {
    @Test func distanceIgnoresGapsBetweenSegments() {
        let track = Track(segments: [
            [point(north: 0), point(north: 100)],
            [point(north: 1000), point(north: 1050)],
        ])
        #expect(abs(track.distance - 150) < 1)
    }

    @Test func elevationGainIgnoresGPSWobble() throws {
        let wobble = (0..<50).map { point(north: Double($0) * 10, elevation: 100 + ($0.isMultiple(of: 2) ? 2 : -2)) }
        #expect(Track(segments: [wobble]).elevationGain() == 0)

        let climb = (0...30).map { point(north: Double($0) * 10, elevation: 100 + Double($0)) }
        let gain = try #require(Track(segments: [climb]).elevationGain())
        #expect(abs(gain - 30) <= 5)
    }

    @Test func noElevationMeansNoGain() {
        #expect(Track(segments: [[point(north: 0), point(north: 10)]]).elevationGain() == nil)
    }
}

@Suite struct MapLinkTests {
    /// A staircase with 20 corners: more turns than Google accepts.
    private var staircase: [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = []
        for step in 0..<20 {
            let east = Double(step) * 200
            points.append(point(north: east, east: east).coordinate)
            points.append(point(north: east + 200, east: east).coordinate)
        }
        return points
    }

    @Test func neverMoreThanTheLimit() {
        #expect(MapLinks.sampleWaypoints(staircase, maxCount: 9).count <= 9)
        #expect(MapLinks.sampleWaypoints(staircase, maxCount: 3).count <= 3)
    }

    @Test func keepsTheCornerOfAnLShape() {
        let up = (0...10).map { point(north: Double($0) * 100).coordinate }
        let across = (1...10).map { point(north: 1000, east: Double($0) * 100).coordinate }
        let waypoints = MapLinks.sampleWaypoints(up + across, maxCount: 9)
        #expect(waypoints == [point(north: 1000).coordinate])
    }

    @Test func aLoopStillGetsWaypoints() {
        // Start and finish are the same spot, so the waypoints are all that give Google a route.
        let loop = [(0.0, 0.0), (1000, 0), (1000, 1000), (0, 1000), (0, 0)].map {
            point(north: $0.0, east: $0.1).coordinate
        }
        #expect(!MapLinks.sampleWaypoints(loop, maxCount: 9).isEmpty)
    }

    @Test func googleRouteLink() throws {
        let track = Track(segments: [[point(north: 0), point(north: 1000), point(north: 1000, east: 1000)]])
        let url = try #require(MapLinks.googleDirections(along: track, maxWaypoints: 9))
        let text = url.absoluteString
        #expect(text.hasPrefix("https://www.google.com/maps/dir/?api=1&origin=37.330000,-122.030000"))
        #expect(text.contains("travelmode=bicycling"))
        #expect(text.contains("waypoints="))
        #expect(!text.contains("|"))
    }

    @Test func directionsToStart() throws {
        let start = CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03)
        #expect(MapLinks.appleDirections(to: start)?.absoluteString
                == "https://maps.apple.com/directions?destination=37.330000,-122.030000&mode=cycling")
        #expect(MapLinks.googleDirections(to: start)?.absoluteString
                == "https://www.google.com/maps/dir/?api=1&destination=37.330000,-122.030000&travelmode=bicycling")
    }
}

@Suite struct RouteLibraryTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func rideTrack() -> Track {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return Track(segments: [(0...40).map {
            point(north: Double($0) * 10, elevation: 50 + Double($0), time: start + Double($0), speed: 6)
        }])
    }

    @Test func savesARouteWithoutTimesOrSpeeds() async throws {
        let library = RouteLibrary(directory: directory)
        let rideID = UUID()
        let route = try #require(library.add(name: "Hill", track: rideTrack(), source: .ride(id: rideID, date: .now)))

        #expect(abs(route.distance - 400) < 2)
        #expect(route.elevationGain != nil)
        #expect(library.route(fromRide: rideID) == route)

        let xml = try String(contentsOf: library.fileURL(for: route), encoding: .utf8)
        #expect(!xml.contains("<time>"))
        #expect(!xml.contains("speed"))
        #expect(xml.contains("<ele>"))
        // A straight line simplifies down to its ends.
        let stored = await library.loadTrack(for: route)
        #expect(stored?.segments.map(\.count) == [2])
    }

    @Test func renameDeleteAndRelaunch() throws {
        let library = RouteLibrary(directory: directory)
        let route = try #require(library.add(name: "Old", track: rideTrack(), source: .imported))

        library.rename(route, to: "  New  ")
        #expect(RouteLibrary(directory: directory).routes.map(\.name) == ["New"])

        library.rename(route, to: "   ")
        #expect(library.routes.first?.name == "New")

        library.delete(route)
        #expect(library.routes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.fileURL(for: route).path))
        #expect(RouteLibrary(directory: directory).routes.isEmpty)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let twoPoints = """
        <trkseg><trkpt lat="37.33" lon="-122.03"/><trkpt lat="37.331" lon="-122.03"/></trkseg>
        """

    @Test func importsWithTheNameInsideTheFile() throws {
        let library = RouteLibrary(directory: directory.appending(path: "routes"))
        let url = try file("download.gpx", "<gpx version=\"1.1\"><trk><name>Ridge Ride</name>\(twoPoints)</trk></gpx>")
        let route = try library.importGPX(from: url)
        #expect(route.name == "Ridge Ride")
        #expect(route.source == .imported)
        #expect(library.routes.first == route)
    }

    @Test func importFallsBackToTheFileName() throws {
        let library = RouteLibrary(directory: directory.appending(path: "routes"))
        let url = try file("Morning Loop.gpx", "<gpx version=\"1.1\"><trk>\(twoPoints)</trk></gpx>")
        #expect(try library.importGPX(from: url).name == "Morning Loop")
    }

    @Test func importErrorsSayWhatWentWrong() throws {
        let library = RouteLibrary(directory: directory.appending(path: "routes"))
        #expect(throws: RouteLibrary.ImportError.noRoute) {
            try library.importGPX(from: file("pins.gpx", #"<gpx version="1.1"><wpt lat="37" lon="-122"/></gpx>"#))
        }
        #expect(throws: RouteLibrary.ImportError.notGPX) {
            try library.importGPX(from: file("broken.gpx", "<gpx><trk>"))
        }
        #expect(throws: RouteLibrary.ImportError.unreadable) {
            try library.importGPX(from: directory.appending(path: "missing.gpx"))
        }

        let huge = try file("huge.gpx", "")
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(RouteLibrary.importSizeLimit + 1))
        try handle.close()
        #expect(throws: RouteLibrary.ImportError.tooLarge) { try library.importGPX(from: huge) }
        #expect(library.routes.isEmpty)
    }

    @Test func refusesAnEmptyTrack() {
        let library = RouteLibrary(directory: directory)
        #expect(library.add(name: "Nothing", track: Track(), source: .imported) == nil)
        #expect(library.routes.isEmpty)
    }
}
