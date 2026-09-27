import SwiftUI

/// A small compass: the heading's compass point (N, NE, E…) in the middle, inside a
/// ring whose red pointer always points north.
struct CompassView: View {
    /// Degrees clockwise from north, or nil when there's no heading yet.
    var heading: Double?
    var size: CGFloat = 80

    /// The heading unwrapped across 0°/360°, so the ring turns the short way round
    /// (359° → 1° is a 2° nudge, not a full spin backwards).
    @State private var rotation: Double = 0

    private static let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    private var point: String {
        guard let heading else { return "--" }
        let index = Int(((heading.truncatingRemainder(dividingBy: 360) + 360 + 22.5) / 45).rounded(.down)) % 8
        return Self.points[index]
    }

    var body: some View {
        let ringWidth: CGFloat = 2
        ZStack {
            // Opaque, so it reads cleanly where it overlaps the speed ring.
            Circle().fill(Color.black)
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: ringWidth)

            ZStack {
                ForEach(0..<8) { i in
                    Capsule()
                        .fill(Color.white.opacity(i.isMultiple(of: 2) ? 0.7 : 0.35))
                        .frame(width: 2, height: i.isMultiple(of: 2) ? 8 : 5)
                        .offset(y: -size / 2 + ringWidth + 6)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                // North pointer, sitting on the ring and pointing outwards.
                Triangle()
                    .fill(Color.red)
                    .frame(width: 14, height: 12)
                    .rotationEffect(.degrees(180))
                    .offset(y: -size / 2 + 3)
            }
            .rotationEffect(.degrees(-rotation))
            .opacity(heading == nil ? 0.3 : 1)

            Text(point)
                .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                .foregroundStyle(heading == nil ? .secondary : .primary)
                .contentTransition(.opacity)
        }
        .frame(width: size, height: size)
        .onChange(of: heading) { old, new in
            guard let new else { return }
            guard let old else {
                rotation = new
                return
            }
            let delta = (new - old + 540).truncatingRemainder(dividingBy: 360) - 180
            withAnimation(.easeOut(duration: 0.3)) { rotation += delta }
        }
        .onAppear { rotation = heading ?? 0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heading == nil ? "Compass, no heading yet" : "Heading \(Self.spoken[point] ?? point)")
    }

    private static let spoken = [
        "N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
        "S": "south", "SW": "southwest", "W": "west", "NW": "northwest",
    ]
}

#Preview {
    HStack(spacing: 20) {
        CompassView(heading: nil)
        CompassView(heading: 47)
        CompassView(heading: 200)
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
