import SwiftUI

struct RideView: View {
    var ride: RideTracker

    @State private var music = MusicControl()
    @State private var flashlight = Flashlight()
    @State private var confirmingEnd = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button("End Ride") { confirmingEnd = true }
                    .font(.headline)
                    .tint(.red)
            }

            SpeedGauge(speed: ride.speed, topSpeed: ride.maxSpeed)
                .frame(maxWidth: 380)

            HStack(spacing: 16) {
                StatTile(title: "DISTANCE") {
                    Text(ride.distance, format: .number.precision(.fractionLength(2)))
                        + Text(" mi").font(.title3).foregroundStyle(.secondary)
                }
                StatTile(title: "TIME") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(Self.format(ride.elapsed(at: context.date)))
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                ControlButton(
                    title: ride.isRunning ? "Stop" : "Start",
                    systemImage: ride.isRunning ? "stop.fill" : "play.fill",
                    tint: ride.isRunning ? .red : .green
                ) { ride.toggleTimer() }

                ControlButton(
                    title: music.isPlaying ? "Pause" : "Music",
                    systemImage: music.isPlaying ? "pause.fill" : "music.note",
                    tint: .pink
                ) { music.toggle() }

                ControlButton(
                    title: flashlight.isOn ? "Light Off" : "Light",
                    systemImage: flashlight.isOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    tint: flashlight.isOn ? .yellow : .gray
                ) { flashlight.toggle() }
                .disabled(!flashlight.isAvailable)
            }
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            music.refresh()
        }
        .confirmationDialog("End this ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End Ride", role: .destructive) {
                if flashlight.isOn { flashlight.toggle() }
                ride.end()
            }
        }
    }

    /// `H:MM:SS.t`, or `MM:SS.t` under an hour.
    static func format(_ interval: TimeInterval) -> String {
        let tenths = Int(interval * 10)
        let h = tenths / 36_000
        let m = tenths / 600 % 60
        let s = tenths / 10 % 60
        let t = tenths % 10
        return h > 0
            ? String(format: "%d:%02d:%02d.%d", h, m, s, t)
            : String(format: "%02d:%02d.%d", m, s, t)
    }
}

private struct StatTile<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
    }
}

private struct ControlButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 20).fill(tint.opacity(0.18)))
        }
        .buttonStyle(PressScaleStyle())
    }
}
