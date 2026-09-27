import CoreLocation
import Foundation
import Testing
@testable import CycleOdometer

/// A fix `north` / `east` metres from a point in Cupertino.
private func fix(north: Double = 0, east: Double = 0, speed: Double = 5, time: Date = .now) -> CLLocation {
    let origin = CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03)
    let coordinate = CLLocationCoordinate2D(
        latitude: origin.latitude + north / 110_540,
        longitude: origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180))
    )
    return CLLocation(coordinate: coordinate, altitude: 42, horizontalAccuracy: 5, verticalAccuracy: 3,
                      course: 0, speed: speed, timestamp: time)
}

@Suite struct TrackRecorderTests {
    @Test func keepsPointsAtLeastFiveMetresApart() {
        var recorder = TrackRecorder()
        let stored = [0, 1, 4.9, 5.5].map { recorder.record(fix(north: $0)) }
        #expect(stored == [true, false, false, true])
        #expect(recorder.track.segments.map(\.count) == [2])
    }

    @Test func pauseStartsANewSegment() {
        var recorder = TrackRecorder()
        recorder.record(fix(north: 0))
        recorder.record(fix(north: 10))
        recorder.breakSegment()
        // Close to the last point, but a new segment always takes its first fix.
        recorder.record(fix(north: 11))
        recorder.record(fix(north: 20))
        #expect(recorder.track.segments.map(\.count) == [2, 2])
    }

    @Test func storesElevationAndSpeed() throws {
        var recorder = TrackRecorder()
        recorder.record(fix(speed: 6.5))
        let point = try #require(recorder.track.segments.first?.first)
        #expect(point.elevation == 42)
        #expect(point.speed == 6.5)
    }

    @Test func singlePointSegmentsAreNotDrawable() {
        var recorder = TrackRecorder()
        recorder.record(fix(north: 0))
        #expect(recorder.track.isEmpty)
        recorder.record(fix(north: 10))
        #expect(!recorder.track.isEmpty)
    }
}

@Suite struct SimplifyTests {
    @Test func straightLineWithSmallJitterKeepsOnlyEnds() {
        let points = (0...100).map { i in
            fix(north: Double(i) * 5, east: i.isMultiple(of: 2) ? 1 : -1).coordinate
        }
        #expect(Simplify.coordinates(points, tolerance: 3).count == 2)
    }

    @Test func keepsCorners() {
        let up = (0...20).map { fix(north: Double($0) * 10).coordinate }
        let across = (1...20).map { fix(north: 200, east: Double($0) * 10).coordinate }
        let simplified = Simplify.coordinates(up + across, tolerance: 3)
        #expect(simplified.count == 3)
        #expect(simplified[1] == fix(north: 200).coordinate)
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }
}

@Suite struct GPXTests {
    @Test func roundTripsSegmentsTimesElevationAndSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000.25)
        var recorder = TrackRecorder()
        recorder.record(fix(north: 0, speed: 4.25, time: start))
        recorder.record(fix(north: 10, speed: 5, time: start + 2))
        recorder.breakSegment()
        recorder.record(fix(north: 100, time: start + 60))
        recorder.record(fix(north: 110, time: start + 62))
        let original = recorder.track

        let xml = GPX.document(for: original, name: "Loop & back <fast>")
        let parsed = try GPX.parse(Data(xml.utf8))

        #expect(parsed.name == "Loop & back <fast>")
        #expect(parsed.track.segments.map(\.count) == [2, 2])
        for (a, b) in zip(original.segments.joined(), parsed.track.segments.joined()) {
            #expect(abs(a.latitude - b.latitude) < 1e-7)
            #expect(abs(a.longitude - b.longitude) < 1e-7)
            #expect(abs(a.time!.timeIntervalSince(b.time!)) < 0.001)
            #expect(abs(a.elevation! - b.elevation!) < 0.05)
            #expect(abs(a.speed! - b.speed!) < 0.005)
        }
    }

    @Test func readsRoutesFromOtherApps() throws {
        // Whole-second times, a metadata name, a route instead of a track, and a waypoint.
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="Komoot" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Hill loop</name></metadata>
          <wpt lat="37.1" lon="-122.1"><name>Café</name></wpt>
          <rte>
            <rtept lat="37.3300" lon="-122.0300"><ele>40</ele><time>2026-09-26T08:00:00Z</time></rtept>
            <rtept lat="37.3310" lon="-122.0300"><name>Turn</name></rtept>
            <rtept lat="37.3310" lon="-122.0290"/>
          </rte>
        </gpx>
        """
        let parsed = try GPX.parse(Data(xml.utf8))
        #expect(parsed.name == "Hill loop")
        #expect(parsed.track.segments.map(\.count) == [3])
        let first = try #require(parsed.track.segments.first?.first)
        #expect(first.elevation == 40)
        #expect(first.time == ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z"))
    }

    @Test func rejectsFilesWithoutARoute() {
        let waypointsOnly = #"<gpx version="1.1"><wpt lat="37.1" lon="-122.1"/></gpx>"#
        #expect(throws: GPX.ParseError.noTrack) { try GPX.parse(Data(waypointsOnly.utf8)) }
        #expect(throws: GPX.ParseError.invalidXML) { try GPX.parse(Data("<gpx><trk>".utf8)) }
    }
}

@Suite struct RideHistoryTests {
    private let directory: URL
    private var historyFile: URL { directory.appending(path: "rides.json") }
    private var tracksDirectory: URL { directory.appending(path: "tracks") }

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    private func sampleTrack() -> Track {
        var recorder = TrackRecorder()
        recorder.record(fix(north: 0))
        recorder.record(fix(north: 50))
        return recorder.track
    }

    private func trackFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: tracksDirectory.path)) ?? []
    }

    @Test func savesAndLoadsATrack() async throws {
        let history = RideHistory(fileURL: historyFile)
        history.add(RideRecord(date: .now, duration: 600, distance: 50, topSpeed: 5), track: sampleTrack())

        let ride = try #require(history.rides.first)
        #expect(ride.hasTrack)
        let loaded = await history.loadTrack(for: ride)
        #expect(loaded?.segments.map(\.count) == [2])

        // And it survives a relaunch.
        let reopened = RideHistory(fileURL: historyFile)
        #expect(reopened.rides.first?.hasTrack == true)
    }

    @Test func rideWithoutAPathHasNoTrack() {
        let history = RideHistory(fileURL: historyFile)
        history.add(RideRecord(date: .now, duration: 600, distance: 0, topSpeed: 0), track: Track())
        #expect(history.rides.first?.hasTrack == false)
        #expect(trackFiles().isEmpty)
    }

    @Test func tracksAreDeletedWithTheirRides() {
        let history = RideHistory(fileURL: historyFile)
        for _ in 0..<(RideHistory.limit + 3) {
            history.add(RideRecord(date: .now, duration: 600, distance: 50, topSpeed: 5), track: sampleTrack())
        }
        #expect(history.rides.count == RideHistory.limit)
        #expect(trackFiles().count == RideHistory.limit)

        history.delete(at: IndexSet(integer: 0))
        #expect(trackFiles().count == RideHistory.limit - 1)
    }

    @Test func removesOrphanedTrackFilesOnLaunch() throws {
        try FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tracksDirectory.appending(path: "\(UUID().uuidString).gpx"))
        _ = RideHistory(fileURL: historyFile)
        #expect(trackFiles().isEmpty)
    }

    @Test func readsHistoryWrittenBeforeTracksExisted() throws {
        let old = """
        [{"id":"\(UUID().uuidString)","date":780000000,"duration":1520,"distance":8050,"topSpeed":9.1}]
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: historyFile)

        let history = RideHistory(fileURL: historyFile)
        #expect(history.rides.count == 1)
        #expect(history.rides.first?.hasTrack == false)
    }
}
