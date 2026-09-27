import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CycleOdometerWidgets: WidgetBundle {
    var body: some Widget {
        RideLiveActivityWidget()
    }
}

/// The ride on the Lock Screen and in the Dynamic Island. Tapping it opens the app.
struct RideLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.85))
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Measure(value: state.speed.formatted(.number.precision(.fractionLength(1))), unit: state.speedUnit)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Measure(value: state.distance.formatted(.number.precision(.fractionLength(2))),
                                unit: state.distanceUnit, size: 22)
                        Clock(state: state)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let route = state.route {
                        RouteRow(route: route)
                    } else if state.isPaused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            } compactLeading: {
                // Speed, and the next turn's arrow when following a route.
                HStack(spacing: 4) {
                    if let route = state.route {
                        Image(systemName: route.symbol)
                            .foregroundStyle(route.isWarning ? .orange : .green)
                    }
                    Text(state.speed.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            } compactTrailing: {
                Text("\(state.distance.formatted(.number.precision(.fractionLength(1)))) \(state.distanceUnit)")
                    .monospacedDigit()
                    .foregroundStyle(.green)
            } minimal: {
                // Sharing the island (e.g. with Google Maps navigation): speed only.
                Text(state.speed.formatted(.number.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}

private struct LockScreenView: View {
    var state: RideActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if state.isFinished {
                    Label("Ride complete", systemImage: "flag.checkered")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else if state.isPaused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                } else {
                    Label("Cycle", systemImage: "bicycle")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline) {
                if !state.isFinished {
                    Measure(value: state.speed.formatted(.number.precision(.fractionLength(1))), unit: state.speedUnit)
                    Spacer()
                }
                Measure(value: state.distance.formatted(.number.precision(.fractionLength(2))), unit: state.distanceUnit)
                Spacer()
                Clock(state: state)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }

            if let route = state.route {
                RouteRow(route: route)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// "20.1 mph": a big number with its unit.
private struct Measure: View {
    var value: String
    var unit: String
    var size: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(unit)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// The ride time: counts itself while the stopwatch runs, so the app needn't send an
/// update every second; stands still when paused.
private struct Clock: View {
    var state: RideActivityAttributes.ContentState

    var body: some View {
        Group {
            if let start = state.timerStart {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
            } else {
                Text(Self.format(state.elapsed))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The next turn (or other route news): "Right in 400 ft · onto Main St · 28%".
private struct RouteRow: View {
    var route: RideActivityAttributes.RouteLine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(route.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(route.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(route.isWarning ? .orange : .white)
    }
}
