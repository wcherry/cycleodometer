import CoreLocation
import Foundation
import Observation
import UIKit

/// Tracks one ride: live GPS speed, the top speed, distance and a stopwatch.
///
/// Distance and top speed only accumulate while the stopwatch is running, so stopping
/// the timer at a café doesn't count GPS drift as riding.
@Observable
final class RideTracker: NSObject, CLLocationManagerDelegate {
    private(set) var isActive = false
    private(set) var isRunning = false

    /// Current speed in mph.
    private(set) var speed: Double = 0
    /// Highest speed reached this ride, in mph.
    private(set) var maxSpeed: Double = 0
    /// Distance travelled this ride, in miles.
    private(set) var distance: Double = 0

    private var accumulated: TimeInterval = 0
    private var runningSince: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastLocation: CLLocation?

    private static let metersPerSecondToMph = 2.236_936
    private static let metersPerMile = 1_609.344

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
        isActive = true

        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
        resume()
    }

    func end() {
        pause()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isActive = false
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

            let mph = location.speed >= 0 ? location.speed * Self.metersPerSecondToMph : 0
            speed = mph

            guard isRunning else { continue }
            maxSpeed = max(maxSpeed, mph)
            if let last = lastLocation {
                distance += location.distance(from: last) / Self.metersPerMile
            }
            lastLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (e.g. no fix yet in a tunnel) are expected; keep listening.
    }
}
