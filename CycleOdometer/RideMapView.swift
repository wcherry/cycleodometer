import MapKit
import SwiftUI

/// The full-screen live map: the ride's track so far, your position, and a compact
/// strip of speed, distance and time. Pause and End stay on the gauge screen.
struct RideMapView: View {
    var ride: RideTracker
    var onClose: () -> Void

    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    /// Heading-up matches the view over the handlebars; north-up suits planning.
    @AppStorage("mapHeadingUp") private var headingUp = true
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    private var following: MapCameraPosition {
        .userLocation(followsHeading: headingUp, fallback: .automatic)
    }

    var body: some View {
        Map(position: $position) {
            ForEach(ride.mapTrack.indices, id: \.self) { index in
                let segment = ride.mapTrack[index]
                if segment.count >= 2 {
                    MapPolyline(coordinates: segment)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapScaleView()
        }
        .onAppear { position = following }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { statsStrip }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Label("Gauge", systemImage: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.glass)

            Spacer()

            // Panning the map stops it following you; this brings it back.
            if !position.followsUserLocation {
                Button {
                    withAnimation { position = following }
                } label: {
                    Label("Recenter", systemImage: "location.fill")
                        .font(.headline)
                }
                .buttonStyle(.glass)
            }

            Button {
                headingUp.toggle()
                withAnimation { position = following }
            } label: {
                Label(headingUp ? "Heading Up" : "North Up",
                      systemImage: headingUp ? "location.north.line.fill" : "n.circle.fill")
                    .font(.headline)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .accessibilityHint("Switches between heading up and north up")
        }
        .padding(.horizontal)
    }

    private var statsStrip: some View {
        HStack(spacing: 0) {
            MapStat(value: units.speed(ride.speed).formatted(.number.precision(.fractionLength(1))),
                    unit: units.speedLabel.lowercased())
            MapStat(value: units.distance(ride.distance).formatted(.number.precision(.fractionLength(2))),
                    unit: units.distanceLabel)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                MapStat(value: Self.clock(ride.elapsed(at: context.date)),
                        unit: ride.isRunning ? "time" : "paused")
            }
        }
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal)
    }

    /// `H:MM:SS`, or `MM:SS` under an hour. Whole seconds: tenths would flicker.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

private struct MapStat: View {
    var value: String
    var unit: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
