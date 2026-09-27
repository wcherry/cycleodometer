import ActivityKit
import Foundation

/// The ride's Live Activity (Dynamic Island and Lock Screen). Compiled into both the
/// app, which starts and updates it, and the widget extension, which draws it.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// In the rider's units at the time of the update.
        var speed: Double
        var speedUnit: String
        var distance: Double
        var distanceUnit: String
        /// Stopwatch time when this update was made, in seconds.
        var elapsed: TimeInterval
        /// While the stopwatch runs: when it would have read zero. Lets the Live Activity
        /// count the time itself, instead of needing an update every second. Nil when paused.
        var timerStart: Date?
        /// The next turn, or other news about the route being followed.
        var route: RouteLine?
        /// The ride has ended: this is its summary.
        var isFinished = false

        var isPaused: Bool { timerStart == nil && !isFinished }
    }

    struct RouteLine: Codable, Hashable {
        var symbol: String
        var title: String
        var detail: String
        /// Off route: drawn in orange.
        var isWarning: Bool
    }
}
