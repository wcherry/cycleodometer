import CoreLocation
import CoreMotion
import Foundation
import Observation
import UIKit

/// Tracks one ride: live GPS speed, the top speed, distance and a stopwatch.
///
/// Values are kept in SI units (m/s, metres); `UnitSystem` converts them for display.
///
/// Distance and top speed only accumulate while the stopwatch is running, so stopping
/// the timer at a café doesn't count GPS drift as riding.
@Observable
final class RideTracker: NSObject, CLLocationManagerDelegate {
    private(set) var isActive = false
    private(set) var isRunning = false

    /// Current speed, in metres per second.
    private(set) var speed: Double = 0
    /// Highest speed reached this ride, in metres per second.
    private(set) var maxSpeed: Double = 0
    /// Distance travelled this ride, in metres.
    private(set) var distance: Double = 0
    /// Direction the top of the phone points, in degrees clockwise from north, or nil
    /// until known. Falls back to the GPS direction of travel without a magnetometer.
    private(set) var heading: Double?
    /// Road grade in percent (rise over run × 100; negative downhill), or nil until
    /// there's been enough riding to measure it.
    private(set) var grade: Double?
    /// Whether this device has a barometer, without which there's no grade at all.
    let canMeasureGrade = CMAltimeter.isRelativeAltitudeAvailable()
    /// The track as drawn on the live map: one polyline per segment, simplified so a
    /// long ride doesn't redraw tens of thousands of points on every fix.
    private(set) var mapTrack: [[CLLocationCoordinate2D]] = []
    /// The route being followed this ride, if any.
    private(set) var route: SavedRoute?
    /// Progress along `route`. Only updated while the timer runs, so stopping at a
    /// café off the route doesn't raise an off-route alert.
    private(set) var follower: RouteFollower?

    private var accumulated: TimeInterval = 0
    @ObservationIgnored private var startDate = Date.now
    private var runningSince: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var recorder = TrackRecorder()
    /// Points added to the last map polyline since it was last simplified.
    @ObservationIgnored private var unsimplifiedCount = 0

    /// Re-simplify the map polyline after this many new points, to about 3 m.
    private static let mapSimplifyInterval = 200
    private static let mapSimplifyTolerance = 3.0

    // Grade: barometric altitude against GPS distance. Kept apart from `distance`,
    // which stops while the timer is paused.
    @ObservationIgnored private let altimeter = CMAltimeter()
    /// Barometric altitude relative to the ride's start, in metres.
    @ObservationIgnored private var altitude: Double?
    @ObservationIgnored private var gradeDistance: Double = 0
    @ObservationIgnored private var gradeLocation: CLLocation?
    @ObservationIgnored private var gradeSamples: [(distance: Double, altitude: Double)] = []

    /// Grade is measured over the last 20–40 m ridden: shorter is noisy, longer lags.
    private static let gradeMinSpan = 20.0
    private static let gradeMaxSpan = 40.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func elapsed(at date: Date = .now) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    /// Starts a ride, following `route` (whose geometry is `track`) if given.
    func start(following route: SavedRoute? = nil, track: Track? = nil) {
        self.route = route
        follower = track.flatMap(RouteFollower.init(track:))
        speed = 0
        maxSpeed = 0
        distance = 0
        accumulated = 0
        lastLocation = nil
        grade = nil
        altitude = nil
        gradeDistance = 0
        gradeLocation = nil
        gradeSamples = []
        recorder.reset()
        mapTrack = []
        unsimplifiedCount = 0
        startDate = .now
        isActive = true

        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            // Portrait: the phone sits upright in a handlebar mount, top facing forward.
            manager.headingOrientation = .portrait
            manager.headingFilter = 2
            manager.startUpdatingHeading()
        }
        if canMeasureGrade {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                self?.altitude = data.relativeAltitude.doubleValue
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        resume()
    }

    /// Stops tracking and returns the finished ride's summary and its track.
    @discardableResult
    func end() -> (record: RideRecord, track: Track) {
        pause()
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
        heading = nil
        route = nil
        follower = nil
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isActive = false
        let record = RideRecord(date: startDate, duration: accumulated, distance: distance, topSpeed: maxSpeed)
        return (record, recorder.track)
    }

    func toggleTimer() {
        isRunning ? pause() : resume()
    }

    private func resume() {
        guard !isRunning else { return }
        runningSince = .now
        // Don't bridge the gap between stop and start with a straight-line distance,
        // on the odometer or on the map.
        lastLocation = nil
        recorder.breakSegment()
        isRunning = true
    }

    private func pause() {
        guard isRunning else { return }
        accumulated = elapsed()
        runningSince = nil
        isRunning = false
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            // Ignore stale or inaccurate fixes; they produce phantom distance and speed spikes.
            guard location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= 25,
                  abs(location.timestamp.timeIntervalSinceNow) < 10 else { continue }

            speed = max(location.speed, 0)
            // GPS course is only meaningful while moving.
            if !CLLocationManager.headingAvailable(), location.course >= 0, location.speed > 1 {
                heading = location.course
            }

            updateGrade(with: location)

            guard isRunning else { continue }
            maxSpeed = max(maxSpeed, speed)
            if let last = lastLocation {
                distance += location.distance(from: last)
            }
            lastLocation = location
            record(location)
            _ = follower?.update(location.coordinate, accuracy: location.horizontalAccuracy, at: location.timestamp)
        }
    }

    private func record(_ location: CLLocation) {
        let segmentCount = recorder.track.segments.count
        guard recorder.record(location) else { return }

        if recorder.track.segments.count > segmentCount || mapTrack.isEmpty {
            mapTrack.append([location.coordinate])
            unsimplifiedCount = 0
            return
        }
        mapTrack[mapTrack.count - 1].append(location.coordinate)
        unsimplifiedCount += 1
        if unsimplifiedCount >= Self.mapSimplifyInterval, let segment = recorder.track.segments.last {
            mapTrack[mapTrack.count - 1] = Simplify.coordinates(
                segment.map(\.coordinate), tolerance: Self.mapSimplifyTolerance)
            unsimplifiedCount = 0
        }
    }

    private func updateGrade(with location: CLLocation) {
        guard let altitude else { return }
        // Standing still, GPS wanders while the altitude doesn't: hold the last grade.
        guard location.speed > 1.5 else {
            gradeLocation = nil
            return
        }
        if let last = gradeLocation {
            gradeDistance += location.distance(from: last)
        }
        gradeLocation = location

        gradeSamples.append((gradeDistance, altitude))
        gradeSamples.removeAll { gradeDistance - $0.distance > Self.gradeMaxSpan }

        guard let oldest = gradeSamples.first else { return }
        let run = gradeDistance - oldest.distance
        guard run >= Self.gradeMinSpan else { return }
        let percent = (altitude - oldest.altitude) / run * 100
        grade = min(max(percent, -30), 30)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Negative accuracy means the reading is invalid (e.g. magnetic interference).
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. no fix yet in a tunnel) are expected; keep listening.
    }
}
