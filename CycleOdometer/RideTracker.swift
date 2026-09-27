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
    /// The route's turns, with street names as they're found.
    private(set) var turns: [Turn] = []
    /// Apple's directions to the route's start (Ride to Start), until you reach it.
    private(set) var approach: GuidanceLeg?
    /// Apple's directions back onto the route after a minute off it.
    private(set) var routeBack: GuidanceLeg?
    /// Where Apple's directions come from; tests substitute canned answers.
    @ObservationIgnored var directions: DirectionsProvider = MapKitDirections()
    /// The Dynamic Island / Lock Screen view of the ride; nil in tests.
    @ObservationIgnored var liveActivity: RideLiveActivity? = RideLiveActivity()

    private var accumulated: TimeInterval = 0
    @ObservationIgnored private var startDate = Date.now
    private var runningSince: Date?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var recorder = TrackRecorder()
    /// Points added to the last map polyline since it was last simplified.
    @ObservationIgnored private var unsimplifiedCount = 0

    @ObservationIgnored private weak var library: RouteLibrary?
    @ObservationIgnored private var wantsApproach = false
    @ObservationIgnored private var approachAttempts = 0
    @ObservationIgnored private var legRequest: Task<Void, Never>?
    @ObservationIgnored private var lastLegRequest: Date?
    @ObservationIgnored private var naming: Task<Void, Never>?

    /// Directions back to the route are offered after this long off it...
    static let routeBackDelay: TimeInterval = 60
    /// ...to a point this far ahead of where you left it, so you aren't sent back.
    static let rejoinAhead = 300.0
    /// Directions are requested at most this often, and Ride to Start tries this
    /// many times before settling for a bearing and distance.
    static let legRequestInterval: TimeInterval = 30
    static let maxApproachAttempts = 3
    /// Pause between street-name lookups, to stay well within Apple's limits.
    static let namingInterval: Duration = .seconds(1.5)

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
    /// `rideToStart` asks for directions to the route's start first. Street names
    /// found for its turns are saved to `library`.
    func start(following route: SavedRoute? = nil, track: Track? = nil,
               library: RouteLibrary? = nil, rideToStart: Bool = false) {
        self.route = route
        self.library = library
        follower = track.flatMap(RouteFollower.init(track:))
        turns = follower.map { TurnDetector.turns(in: $0.line) } ?? []
        approach = nil
        routeBack = nil
        wantsApproach = rideToStart && follower != nil
        approachAttempts = 0
        lastLegRequest = nil
        if let route, !turns.isEmpty {
            nameTurns(of: route)
        }
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
        let snapshot = liveActivitySnapshot()
        liveActivity?.start(snapshot.state, key: snapshot.key)
    }

    /// Stops tracking and returns the finished ride's summary and its track.
    @discardableResult
    func end() -> (record: RideRecord, track: Track) {
        pause()
        var summary = liveActivitySnapshot().state
        summary.route = nil
        summary.isFinished = true
        liveActivity?.end(summary)
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        altimeter.stopRelativeAltitudeUpdates()
        heading = nil
        naming?.cancel()
        legRequest?.cancel()
        naming = nil
        legRequest = nil
        route = nil
        follower = nil
        turns = []
        approach = nil
        routeBack = nil
        manager.allowsBackgroundLocationUpdates = false
        UIApplication.shared.isIdleTimerDisabled = false
        isActive = false
        let record = RideRecord(date: startDate, duration: accumulated, distance: distance, topSpeed: maxSpeed)
        return (record, recorder.track)
    }

    func toggleTimer() {
        isRunning ? pause() : resume()
        updateLiveActivity()
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
        defer { updateLiveActivity() }
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
            if var follower {
                _ = follower.update(location.coordinate, accuracy: location.horizontalAccuracy, at: location.timestamp)
                self.follower = follower
                updateGuidance(at: location, on: follower)
            }
        }
    }

    // MARK: Live Activity

    /// What the Live Activity should show now, and a key summarising what about it is
    /// urgent (pausing, the next turn and how close it is, going off route): when the
    /// key changes, the update goes out straight away.
    func liveActivitySnapshot() -> (state: RideActivityAttributes.ContentState, key: String) {
        let units = UnitSystem.current
        var key = "running:\(isRunning)"
        var line: RideActivityAttributes.RouteLine?
        if let follower {
            let cue = currentCue
            let text = RouteStatusText(status: RouteStatus(follower: follower, recentlyRejoined: false, cue: cue),
                                       follower: follower, routeName: route?.name ?? "Route", units: units)
            line = .init(symbol: text.symbol, title: text.title, detail: text.detail, isWarning: text.isWarning)
            key += "|cue:\(cue.map { "\($0.kind)/\($0.stage)" } ?? "-")|off:\(follower.isOffRoute)"
                + "|joined:\(follower.hasJoined)|done:\(follower.isFinished)"
        }
        let state = RideActivityAttributes.ContentState(
            // Rounded as displayed, so noise in the last digits doesn't count as a change.
            speed: (units.speed(speed) * 10).rounded() / 10,
            speedUnit: units.speedLabel.lowercased(),
            distance: (units.distance(distance) * 100).rounded() / 100,
            distanceUnit: units.distanceLabel,
            elapsed: elapsed(),
            timerStart: runningSince.map { $0 - accumulated },
            route: line
        )
        return (state, key)
    }

    private func updateLiveActivity() {
        guard isActive, let liveActivity else { return }
        let snapshot = liveActivitySnapshot()
        liveActivity.update(snapshot.state, key: snapshot.key)
    }

    // MARK: Route guidance

    /// The next thing to tell the rider: a turn on the route, or a step of the
    /// directions to its start or back onto it.
    var currentCue: Cue? {
        guard let follower else { return nil }
        if !follower.hasJoined, let step = approach?.nextStep {
            return Cue(kind: .leg(.toStart, step: step.index), symbol: DirectionText.symbol(for: step.instructions),
                       instruction: step.instructions, distance: step.distance)
        }
        if follower.isOffRoute, let step = routeBack?.nextStep {
            return Cue(kind: .leg(.backToRoute, step: step.index), symbol: DirectionText.symbol(for: step.instructions),
                       instruction: step.instructions, distance: step.distance)
        }
        guard follower.hasJoined, !follower.isOffRoute, !follower.isFinished,
              let index = turns.firstIndex(where: { $0.along > follower.progress + 5 }) else { return nil }
        let turn = turns[index]
        return Cue(kind: .turn(index), symbol: turn.direction.symbol, instruction: turn.direction.phrase,
                   street: turn.streetName, distance: turn.along - follower.progress)
    }

    private func updateGuidance(at location: CLLocation, on follower: RouteFollower) {
        let position = location.coordinate, time = location.timestamp

        // Riding to the start: directions until the route is reached.
        if follower.hasJoined {
            approach = nil
            wantsApproach = false
        } else if wantsApproach {
            if var leg = approach {
                approach = leg.update(position, at: time) ? leg : nil
            }
            if approach == nil, approachAttempts < Self.maxApproachAttempts, let start = follower.coordinates.first {
                requestLeg(.toStart, from: position, to: start)
            }
        }

        // Back to the route after a minute off it, rejoining a little further on.
        if !follower.isOffRoute {
            routeBack = nil
        } else if let since = follower.offRouteSince, time.timeIntervalSince(since) >= Self.routeBackDelay {
            if var leg = routeBack {
                routeBack = leg.update(position, at: time) ? leg : nil
            }
            if routeBack == nil {
                let rejoin = follower.line.coordinate(follower.line.point(at: follower.progress + Self.rejoinAhead))
                requestLeg(.backToRoute, from: position, to: rejoin)
            }
        }
    }

    private func requestLeg(_ purpose: GuidanceLeg.Purpose, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        guard legRequest == nil,
              lastLegRequest.map({ Date.now.timeIntervalSince($0) >= Self.legRequestInterval }) ?? true else { return }
        lastLegRequest = .now
        if purpose == .toStart { approachAttempts += 1 }
        let provider = directions
        legRequest = Task { @MainActor [weak self] in
            let route = try? await provider.cyclingRoute(from: from, to: to)
            guard let self, !Task.isCancelled else { return }
            self.legRequest = nil
            guard let route, let leg = GuidanceLeg(purpose: purpose, route: route) else { return }
            // Only if it's still wanted: you may have reached the route meanwhile.
            switch purpose {
            case .toStart where self.wantsApproach && self.follower?.hasJoined == false:
                self.approach = leg
            case .backToRoute where self.follower?.isOffRoute == true:
                self.routeBack = leg
            default:
                break
            }
        }
    }

    /// Fills in street names for the route's turns: saved ones straight away, the
    /// rest looked up one at a time in the background and saved as they're found,
    /// so a route is only ever looked up once. Lookups that fail (offline) aren't
    /// saved, and are tried again the next time the route is ridden.
    private func nameTurns(of route: SavedRoute) {
        var names: [String] = []
        if let saved = route.turnNames, saved.turnCount == turns.count {
            names = saved.names
        }
        for (index, name) in names.enumerated() where !name.isEmpty && index < turns.count {
            turns[index].streetName = name
        }
        guard StreetNameSetting.isOn, names.count < turns.count, let line = follower?.line else { return }

        let turnsToName = turns, provider = directions, alreadyNamed = names
        naming = Task { @MainActor [weak self] in
            var names = alreadyNamed
            for index in alreadyNamed.count..<turnsToName.count {
                if index > alreadyNamed.count { try? await Task.sleep(for: Self.namingInterval) }
                guard !Task.isCancelled else { return }
                let lookup = await StreetNames.name(forTurn: index, of: turnsToName, on: line, using: provider)
                guard let self, !Task.isCancelled else { return }
                switch lookup {
                case .failed:
                    return
                case .notFound:
                    names.append("")
                case .found(let name):
                    names.append(name)
                    if index < self.turns.count { self.turns[index].streetName = name }
                }
                self.library?.saveTurnNames(TurnNames(turnCount: turnsToName.count, names: names), for: route)
            }
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
