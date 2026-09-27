import ActivityKit
import Foundation

/// Decides when the Live Activity gets an update. iOS rations them, so the time ticks
/// by itself and routine changes (speed, distance) go out at most every few seconds;
/// anything the rider needs to know now (a pause, a new turn, the countdown to it,
/// going off route) goes out straight away.
struct LiveActivityThrottle {
    static let routineInterval: TimeInterval = 5

    private var lastState: RideActivityAttributes.ContentState?
    private var lastKey: String?
    private var lastSent = Date.distantPast

    /// Whether to send `state`. `key` summarises what's urgent: when it changes, send now.
    mutating func shouldSend(_ state: RideActivityAttributes.ContentState, key: String, at now: Date) -> Bool {
        guard state != lastState else { return false }
        guard key != lastKey || now.timeIntervalSince(lastSent) >= Self.routineInterval else { return false }
        lastState = state
        lastKey = key
        lastSent = now
        return true
    }
}

/// Starts, updates and ends the ride's Live Activity. Does nothing if the rider has
/// turned Live Activities off for the app.
final class RideLiveActivity {
    /// The summary stays on the Lock Screen this long after the ride ends.
    static let summaryDuration: TimeInterval = 5 * 60
    /// If the app stops updating (killed mid-ride), iOS dims the activity after this.
    static let staleAfter: TimeInterval = 2 * 60

    private var activity: Activity<RideActivityAttributes>?
    private var throttle = LiveActivityThrottle()

    func start(_ state: RideActivityAttributes.ContentState, key: String) {
        // Clear any left behind by a ride the app didn't get to end (it was killed).
        for leftover in Activity<RideActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        throttle = LiveActivityThrottle()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = throttle.shouldSend(state, key: key, at: .now)
        activity = try? Activity.request(attributes: RideActivityAttributes(), content: content(state))
    }

    func update(_ state: RideActivityAttributes.ContentState, key: String) {
        guard let activity, throttle.shouldSend(state, key: key, at: .now) else { return }
        let content = content(state)
        Task { await activity.update(content) }
    }

    func end(_ summary: RideActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: summary, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(.now + Self.summaryDuration)) }
    }

    private func content(_ state: RideActivityAttributes.ContentState) -> ActivityContent<RideActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: .now + Self.staleAfter)
    }
}
