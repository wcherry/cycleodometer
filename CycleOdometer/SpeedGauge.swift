import SwiftUI

/// A 270° gauge, open at the bottom, running from 0 to `maxValue` mph.
/// A triangular bug on the outside of the ring marks the top speed.
struct SpeedGauge: View {
    var speed: Double
    var topSpeed: Double
    var maxValue: Double = 30

    private let sweep = 0.75
    /// Rotation that moves the ring's start (3 o'clock) round to 7:30.
    private let startAngle = 135.0

    private func fraction(_ value: Double) -> Double {
        min(max(value / maxValue, 0), 1)
    }

    /// Angle in degrees, clockwise from 3 o'clock, for a value on the gauge.
    private func angle(for value: Double) -> Double {
        startAngle + fraction(value) * sweep * 360
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let lineWidth = size * 0.07
            let radius = size / 2 - lineWidth * 1.6

            ZStack {
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .trim(from: 0, to: sweep * fraction(speed))
                    .stroke(
                        AngularGradient(
                            colors: [.green, .yellow, .orange, .red],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(sweep * 360)
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)
                    .animation(.easeOut(duration: 0.4), value: speed)

                ForEach(Array(stride(from: 0, through: Int(maxValue), by: 5)), id: \.self) { tick in
                    let a = Angle.degrees(angle(for: Double(tick))).radians
                    let r = radius - lineWidth * 1.35
                    Text("\(tick)")
                        .font(.system(size: size * 0.05, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .position(x: size / 2 + cos(a) * r, y: size / 2 + sin(a) * r)
                }

                // Top-speed bug, sitting just outside the ring and pointing inward.
                let bugAngle = angle(for: topSpeed)
                let bugRadius = radius + lineWidth * 1.05
                let b = Angle.degrees(bugAngle).radians
                Triangle()
                    .fill(Color.cyan)
                    .frame(width: lineWidth * 0.9, height: lineWidth * 0.8)
                    // The triangle's tip points down (90°); turn it to face the centre.
                    .rotationEffect(.degrees(bugAngle + 90))
                    .position(x: size / 2 + cos(b) * bugRadius, y: size / 2 + sin(b) * bugRadius)
                    .animation(.easeOut(duration: 0.4), value: topSpeed)

                VStack(spacing: 0) {
                    Text(speed, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("MPH")
                        .font(.system(size: size * 0.06, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Label {
                        Text(topSpeed, format: .number.precision(.fractionLength(1)))
                    } icon: {
                        Image(systemName: "arrowtriangle.down.fill")
                    }
                    .font(.system(size: size * 0.05, weight: .medium, design: .rounded))
                    .foregroundStyle(.cyan)
                    .monospacedDigit()
                    .padding(.top, size * 0.02)
                }
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed \(Int(speed.rounded())) miles per hour, top speed \(Int(topSpeed.rounded()))")
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}

#Preview {
    SpeedGauge(speed: 17.4, topSpeed: 24.8)
        .padding()
        .preferredColorScheme(.dark)
}
