import SwiftUI

/// What to tell the rider about the route they're following.
enum RouteStatus: Equatable {
    /// Not on the route yet (e.g. started away from it). Distance and bearing to it.
    case approaching(distance: Double?, bearing: Double?)
    case onRoute
    case offRoute(distance: Double, bearing: Double?)
    /// Shown for a few seconds after rejoining.
    case backOnRoute
    case finished

    init(follower: RouteFollower, recentlyRejoined: Bool) {
        if follower.isOffRoute {
            self = .offRoute(distance: follower.distanceFromRoute ?? 0, bearing: follower.bearingToRoute)
        } else if !follower.hasJoined {
            self = .approaching(distance: follower.distanceFromRoute, bearing: follower.bearingToRoute)
        } else if follower.isFinished {
            self = .finished
        } else if recentlyRejoined {
            self = .backOnRoute
        } else {
            self = .onRoute
        }
    }
}

extension UnitSystem {
    /// A short distance for "120 ft away": feet (to the nearest 10) under a tenth
    /// of a mile, metres under a kilometre, otherwise miles or kilometres.
    func shortDistance(_ meters: Double) -> String {
        switch self {
        case .imperial:
            let feet = meters * 3.280_84
            return feet < 528
                ? "\(Int((feet / 10).rounded()) * 10) ft"
                : "\(distance(meters).formatted(.number.precision(.fractionLength(1)))) mi"
        case .metric:
            return meters < 1_000
                ? "\(Int((meters / 10).rounded()) * 10) m"
                : "\(distance(meters).formatted(.number.precision(.fractionLength(1)))) km"
        }
    }

    /// e.g. "3.2 of 11.5 mi · 28%".
    func progress(_ follower: RouteFollower) -> String {
        let done = distance(follower.progress).formatted(.number.precision(.fractionLength(1)))
        let total = distance(follower.length).formatted(.number.precision(.fractionLength(1)))
        let percent = follower.length > 0 ? Int((follower.progress / follower.length * 100).rounded()) : 0
        return "\(done) of \(total) \(distanceLabel) · \(min(percent, 100))%"
    }
}

/// The route card: where you are on the route, or which way to go to get back to it.
/// On the gauge screen it sits on a solid tile; over the map it uses glass.
struct RouteStatusCard: View {
    var status: RouteStatus
    var follower: RouteFollower
    var routeName: String
    /// The phone's heading, to point the arrow back to the route relative to you.
    var heading: Double?
    var onMap = false

    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial

    var body: some View {
        HStack(spacing: 14) {
            icon
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint == .primary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if onMap {
                Color.clear.glassEffect(.regular.tint(tint == .primary ? nil : tint.opacity(0.35)),
                                        in: .rect(cornerRadius: 18))
            } else {
                TilePlate(cornerRadius: 16, tint: (tint == .primary ? Color.white : tint).opacity(tint == .primary ? 0.08 : 0.18))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .approaching(_, let bearing), .offRoute(_, let bearing):
            // Relative to where the phone faces, when we know; otherwise just a warning.
            if let bearing, let heading {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(bearing - heading))
                    .accessibilityLabel("Arrow towards the route")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
            }
        case .onRoute:
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        case .backOnRoute:
            Image(systemName: "checkmark.circle.fill")
        case .finished:
            Image(systemName: "flag.checkered")
        }
    }

    private var title: String {
        switch status {
        case .approaching(let distance, _):
            distance.map { "Route \(units.shortDistance($0)) away" } ?? "Head to the route"
        case .onRoute: routeName
        case .offRoute(let distance, _): "Off route · \(units.shortDistance(distance))"
        case .backOnRoute: "Back on route"
        case .finished: "Route complete"
        }
    }

    private var detail: String {
        switch status {
        case .approaching: routeName
        case .finished: "\(routeName) · \(units.distance(follower.length).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)"
        default: units.progress(follower)
        }
    }

    private var tint: Color {
        switch status {
        case .offRoute: .orange
        case .backOnRoute, .finished: .green
        case .approaching: .cyan
        case .onRoute: .primary
        }
    }
}
