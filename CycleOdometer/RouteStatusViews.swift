import SwiftUI

/// The next thing to tell the rider: a turn on the route, or a step of Apple's
/// directions to the route's start or back onto it.
struct Cue: Equatable {
    enum Kind: Equatable {
        case turn(Int)
        case leg(GuidanceLeg.Purpose, step: Int)
    }

    var kind: Kind
    var symbol: String
    /// "Right" for a turn; Apple's full instruction for a directions step.
    var instruction: String
    var street: String? = nil
    /// Metres until the turn or step.
    var distance: Double

    /// How close the turn is, for the haptic countdown: 1 within 150 m, 2 within 30 m.
    var stage: Int {
        distance <= 30 ? 2 : distance <= 150 ? 1 : 0
    }
}

/// What to tell the rider about the route they're following.
enum RouteStatus: Equatable {
    /// Not on the route yet (e.g. started away from it). Distance and bearing to it.
    case approaching(distance: Double?, bearing: Double?, cue: Cue?)
    case onRoute(cue: Cue?)
    case offRoute(distance: Double, bearing: Double?, cue: Cue?)
    /// Shown for a few seconds after rejoining.
    case backOnRoute
    case finished

    init(follower: RouteFollower, recentlyRejoined: Bool, cue: Cue?) {
        if follower.isOffRoute {
            self = .offRoute(distance: follower.distanceFromRoute ?? 0, bearing: follower.bearingToRoute, cue: cue)
        } else if !follower.hasJoined {
            self = .approaching(distance: follower.distanceFromRoute, bearing: follower.bearingToRoute, cue: cue)
        } else if follower.isFinished {
            self = .finished
        } else if recentlyRejoined {
            self = .backOnRoute
        } else {
            self = .onRoute(cue: cue)
        }
    }

    /// On route with nothing to say: the map leaves the card off.
    var isQuiet: Bool { self == .onRoute(cue: nil) }
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

    /// e.g. "28%".
    func percent(_ follower: RouteFollower) -> String {
        let percent = follower.length > 0 ? Int((follower.progress / follower.length * 100).rounded()) : 0
        return "\(min(percent, 100))%"
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

    private var cue: Cue? {
        switch status {
        case .approaching(_, _, let cue), .onRoute(let cue), .offRoute(_, _, let cue): cue
        case .backOnRoute, .finished: nil
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let cue {
            Image(systemName: cue.symbol)
        } else {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .approaching(_, let bearing, _), .offRoute(_, let bearing, _):
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
        if let cue {
            // A turn reads "Right in 400 ft"; Apple's steps are already sentences.
            if case .turn = cue.kind { return "\(cue.instruction) in \(units.shortDistance(cue.distance))" }
            return cue.instruction
        }
        switch status {
        case .approaching(let distance, _, _):
            return distance.map { "Route \(units.shortDistance($0)) away" } ?? "Head to the route"
        case .onRoute: return routeName
        case .offRoute(let distance, _, _): return "Off route · \(units.shortDistance(distance))"
        case .backOnRoute: return "Back on route"
        case .finished: return "Route complete"
        }
    }

    private var detail: String {
        if let cue {
            switch cue.kind {
            case .turn:
                return cue.street.map { "onto \($0) · \(units.percent(follower))" } ?? units.progress(follower)
            case .leg(.toStart, _):
                return "In \(units.shortDistance(cue.distance)) · Riding to the start"
            case .leg(.backToRoute, _):
                return "In \(units.shortDistance(cue.distance)) · Back to the route"
            }
        }
        switch status {
        case .approaching: return routeName
        case .finished: return "\(routeName) · \(units.distance(follower.length).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)"
        default: return units.progress(follower)
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
