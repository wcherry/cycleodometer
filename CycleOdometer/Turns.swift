import CoreLocation
import Foundation

/// A turn on a route, found from the route's shape.
struct Turn: Equatable {
    enum Direction: Equatable {
        case slightLeft, left, sharpLeft
        case slightRight, right, sharpRight
        case uTurn

        /// From the change of heading in degrees: positive is to the right.
        init?(angle: Double) {
            let size = abs(angle)
            guard size > TurnDetector.minimumAngle else { return nil }
            let right = angle > 0
            switch size {
            case ..<60: self = right ? .slightRight : .slightLeft
            case ..<120: self = right ? .right : .left
            case ..<170: self = right ? .sharpRight : .sharpLeft
            default: self = .uTurn
            }
        }

        /// As a cue: "Right in 400 ft".
        var phrase: String {
            switch self {
            case .slightLeft: "Bear left"
            case .left: "Left"
            case .sharpLeft: "Sharp left"
            case .slightRight: "Bear right"
            case .right: "Right"
            case .sharpRight: "Sharp right"
            case .uTurn: "U-turn"
            }
        }

        var symbol: String {
            switch self {
            case .slightLeft: "arrow.up.left"
            case .left: "arrow.turn.up.left"
            case .sharpLeft: "arrow.turn.left.down"
            case .slightRight: "arrow.up.right"
            case .right: "arrow.turn.up.right"
            case .sharpRight: "arrow.turn.right.down"
            case .uTurn: "arrow.uturn.down"
            }
        }
    }

    /// Distance along the route to the turn, in metres.
    var along: Double
    var direction: Direction
    var coordinate: CLLocationCoordinate2D
    /// The street you turn onto, when known.
    var streetName: String?

    static func == (a: Turn, b: Turn) -> Bool {
        a.along == b.along && a.direction == b.direction && a.streetName == b.streetName
    }
}

/// Finds the turns in a route. See "How the shape-based cues work" in
/// docs/features/routes-and-maps.md.
enum TurnDetector {
    /// Straightened to this many metres first, so GPS wiggle doesn't read as turns.
    static let simplifyTolerance = 10.0
    /// The heading in and out of a corner is measured over this far either side.
    static let headingSpan = 30.0
    /// Changes of heading smaller than this aren't turns.
    static let minimumAngle = 30.0
    /// Turns closer together than this become one cue (a road jog).
    static let mergeDistance = 25.0

    static func turns(in line: Polyline) -> [Turn] {
        let corners = Simplify.indices(of: line.coordinates, tolerance: simplifyTolerance)
            .dropFirst().dropLast()

        var found: [(along: Double, angle: Double)] = []
        for index in corners {
            let along = line.cumulative[index]
            // Too close to either end to measure both headings.
            guard along >= headingSpan / 2, line.length - along >= headingSpan / 2 else { continue }
            let before = line.point(at: along - headingSpan)
            let at = line.point(at: along)
            let after = line.point(at: along + headingSpan)
            let angle = Self.change(from: Polyline.bearing(from: before, to: at),
                                    to: Polyline.bearing(from: at, to: after))
            if abs(angle) > minimumAngle {
                found.append((along, angle))
            }
        }

        // Merge close turns: keep the first position; the net change decides the
        // direction, unless they cancel out (a jog), when the first one does.
        var merged: [(along: Double, angle: Double, first: Double)] = []
        for turn in found {
            if let last = merged.last, turn.along - last.along < mergeDistance {
                merged[merged.count - 1].angle += turn.angle
            } else {
                merged.append((turn.along, turn.angle, turn.angle))
            }
        }

        return merged.compactMap { turn in
            guard let direction = Turn.Direction(angle: turn.angle) ?? Turn.Direction(angle: turn.first) else { return nil }
            return Turn(along: turn.along, direction: direction, coordinate: line.coordinate(line.point(at: turn.along)))
        }
    }

    /// The signed change from one heading to another, in (-180, 180]: positive is right.
    static func change(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

/// Street names from Apple's direction text, e.g. "Turn right onto Main St".
///
/// Apple gives no separate street-name field, so this reads the text. It understands
/// English; in other languages it finds nothing, and cues simply have no names.
enum DirectionText {
    static func streetName(in instruction: String) -> String? {
        for marker in [" onto ", " on ", " toward ", " towards "] {
            if let range = instruction.range(of: marker, options: .caseInsensitive) {
                let name = instruction[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    /// An arrow for a step's instruction.
    static func symbol(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("arrive") || text.contains("destination") { return "flag.checkered" }
        let slight = text.contains("slight") || text.contains("bear") || text.contains("keep")
        if text.contains("left") { return slight ? "arrow.up.left" : "arrow.turn.up.left" }
        if text.contains("right") { return slight ? "arrow.up.right" : "arrow.turn.up.right" }
        return "arrow.up"
    }
}
