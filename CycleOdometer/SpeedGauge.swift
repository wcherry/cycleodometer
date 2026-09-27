import SwiftUI

/// A 270° gauge, open at the bottom, running from 0 to `maxValue`.
/// A triangular bug on the ring marks the top speed. Values are in whatever unit
/// `unitLabel` names; the gauge doesn't convert.
struct SpeedGauge: View {
    var speed: Double
    var topSpeed: Double
    var maxValue: Double = 30
    var tickStep: Int = 5
    var unitLabel: String = "MPH"
    var unitName: String = "miles per hour"
    /// Road grade in percent; nil shows "--%". Hidden entirely when `showsGrade` is false.
    var grade: Double?
    var showsGrade = false

    private let sweep = 0.75
    /// Rotation that moves the ring's start (3 o'clock) round to 7:30.
    private let startAngle = 135.0

    private var accessibilityText: String {
        var text = "Speed \(Int(speed.rounded())) \(unitName), top speed \(Int(topSpeed.rounded()))"
        if showsGrade, let grade {
            text += ", grade \(Int(grade.rounded())) percent"
        }
        return text
    }

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
            // The ring's outer edge touches the frame, so the ring fills the gauge's width.
            let radius = (size - lineWidth) / 2

            ZStack {
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)

                Circle()
                    .trim(from: 0, to: sweep * fraction(speed))
                    .stroke(
                        Color.green,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(startAngle))
                    .frame(width: radius * 2, height: radius * 2)
                    .animation(.easeOut(duration: 0.4), value: speed)

                ForEach(Array(stride(from: 0, through: Int(maxValue), by: tickStep)), id: \.self) { tick in
                    let a = Angle.degrees(angle(for: Double(tick))).radians
                    let r = radius - lineWidth * 1.35
                    Text("\(tick)")
                        .font(.system(size: size * 0.05, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .position(x: size / 2 + cos(a) * r, y: size / 2 + sin(a) * r)
                }

                // Top-speed bug: its base on the ring's outer edge, pointing inward across
                // the stroke, outlined so it stands out against the green fill.
                let bugAngle = angle(for: topSpeed)
                let bugHeight = lineWidth * 0.9
                let bugRadius = radius + lineWidth / 2 - bugHeight / 2
                let b = Angle.degrees(bugAngle).radians
                Triangle()
                    .fill(Color.cyan)
                    .overlay(Triangle().stroke(Color.black, lineWidth: 1.5))
                    .frame(width: lineWidth * 1.1, height: bugHeight)
                    // The triangle's tip points down (90°); turn it to face the centre.
                    .rotationEffect(.degrees(bugAngle + 90))
                    .position(x: size / 2 + cos(b) * bugRadius, y: size / 2 + sin(b) * bugRadius)
                    .animation(.easeOut(duration: 0.4), value: topSpeed)

                VStack(spacing: 0) {
                    if showsGrade {
                        GradeLabel(grade: grade)
                            .font(.system(size: size * 0.07, weight: .semibold, design: .rounded))
                    }
                    Text(speed, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unitLabel)
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
        .accessibilityLabel(accessibilityText)
    }
}

/// "↗ 5%": an arrow for uphill, downhill or level, then the grade to the nearest percent.
private struct GradeLabel: View {
    var grade: Double?

    var body: some View {
        let rounded = grade.map { Int($0.rounded()) }
        Label {
            Text(rounded.map { "\($0)%" } ?? "--%")
                .monospacedDigit()
        } icon: {
            Image(systemName: icon(for: rounded))
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(rounded.map { "Grade \($0) percent" } ?? "Grade unknown")
    }

    private func icon(for grade: Int?) -> String {
        switch grade {
        case let g? where g > 0: "arrow.up.right"
        case let g? where g < 0: "arrow.down.right"
        default: "arrow.right"
        }
    }
}

/// A triangle whose tip points down.
struct Triangle: Shape {
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
