import MapKit
import SwiftUI

/// One past ride: its track on a map, with start and finish marked, and its stats.
struct RideDetailView: View {
    var ride: RideRecord
    var history: RideHistory

    @Environment(RouteLibrary.self) private var library
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @State private var track: Track?
    @State private var isLoading = true
    @State private var naming = false
    @State private var routeName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                mapSection
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        DetailTile(title: "TIME", value: RideMapView.clock(ride.duration), unit: nil)
                        DetailTile(title: "DISTANCE",
                                   value: units.distance(ride.distance).formatted(.number.precision(.fractionLength(2))),
                                   unit: units.distanceLabel)
                    }
                    GridRow {
                        DetailTile(title: "TOP SPEED",
                                   value: units.speed(ride.topSpeed).formatted(.number.precision(.fractionLength(1))),
                                   unit: units.speedLabel.lowercased())
                        DetailTile(title: "AVG SPEED",
                                   value: units.speed(ride.averageSpeed).formatted(.number.precision(.fractionLength(1))),
                                   unit: units.speedLabel.lowercased())
                    }
                }

                saveAsRoute
            }
            .padding()
        }
        .navigationTitle(ride.date.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            track = await history.loadTrack(for: ride)
            isLoading = false
        }
        .alert("Save as Route", isPresented: $naming) {
            TextField("Name", text: $routeName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Routes are kept until you delete them, even after this ride leaves your history.")
        }
    }

    /// Save as Route, or a link to the route once it's been saved.
    @ViewBuilder
    private var saveAsRoute: some View {
        if let saved = library.route(fromRide: ride.id) {
            NavigationLink(value: saved) {
                Label("Saved as “\(saved.name)”", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button {
                routeName = defaultRouteName
                naming = true
            } label: {
                Label("Save as Route", systemImage: "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(track?.isEmpty ?? true)
        }
    }

    /// e.g. "Sat, Sep 26, 11.5 mi".
    private var defaultRouteName: String {
        let date = ride.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let distance = units.distance(ride.distance).formatted(.number.precision(.fractionLength(1)))
        return "\(date), \(distance) \(units.distanceLabel)"
    }

    private func save() {
        guard let track else { return }
        let name = routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        library.add(name: name.isEmpty ? defaultRouteName : name, track: track,
                    source: .ride(id: ride.id, date: ride.date))
    }

    @ViewBuilder
    private var mapSection: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.06))
        } else if let track, !track.isEmpty {
            TrackMap(track: track)
        } else {
            ContentUnavailableView(
                "No Route Recorded",
                systemImage: "map",
                description: Text(ride.hasTrack
                    ? "This ride's route couldn't be read."
                    : "Rides recorded before route recording was added don't have a map.")
            )
            .background(Color.white.opacity(0.06))
        }
    }
}

/// A finished track, framed to fit, with a green start dot and a chequered flag at
/// the finish. Used for rides and saved routes.
struct TrackMap: View {
    var track: Track

    /// Simplified once: a long ride's full track is far more than the map needs.
    private let segments: [[CLLocationCoordinate2D]]

    init(track: Track) {
        self.track = track
        segments = track.drawableSegments.map {
            Simplify.coordinates($0.map(\.coordinate), tolerance: 3)
        }
    }

    var body: some View {
        Map(initialPosition: framing) {
            ForEach(segments.indices, id: \.self) { index in
                MapPolyline(coordinates: segments[index])
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = segments.first?.first {
                Annotation("Start", coordinate: start) {
                    Circle()
                        .fill(Color.green)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 18, height: 18)
                }
            }
            if let finish = segments.last?.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: finish)
                    .tint(.black)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    /// The whole track with a margin on every side, so the start and finish markers
    /// aren't pressed against the edge (`.automatic` fits the track edge to edge).
    private var framing: MapCameraPosition {
        let points = segments.joined().map(MKMapPoint.init)
        guard let first = points.first else { return .automatic }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        // A quarter of the track's size, and at least 150 m (map points aren't metres).
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(first.coordinate.latitude)
        let margin = max(max(rect.width, rect.height) * 0.25, 150 * pointsPerMeter)
        return .rect(rect.insetBy(dx: -margin, dy: -margin))
    }
}

struct DetailTile: View {
    var title: String
    var value: String
    var unit: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}
