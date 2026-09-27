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

    private var accumulated: TimeInterval = 0
    @ObservationIgnored private var startDate = Date.now
    private var runningSince: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastLocation: CLLocation?

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

    func start() {
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

    /// Stops tracking and returns the finished ride's summary.
    @discardableResult
    func end() -> RideRecord {
        pause()
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
        heading = nil
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isActive = false
        return RideRecord(date: startDate, duration: accumulated, distance: distance, topSpeed: maxSpeed)
    }

    func toggleTimer() {
        isRunning ? pause() : resume()
    }

    private func resume() {
        guard !isRunning else { return }
        runningSince = .now
        // Don't bridge the gap between stop and start with a straight-line distance.
        lastLocation = nil
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
