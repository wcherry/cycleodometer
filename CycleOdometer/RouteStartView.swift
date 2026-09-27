import CoreLocation
import SwiftUI

/// The last step before riding a route: the route, how far away its start is, and
/// Start. Far from the start, it offers directions there in Apple or Google Maps.
struct RouteStartView: View {
    var route: SavedRoute

    @Environment(RouteLibrary.self) private var library
    @Environment(RideTracker.self) private var ride
    @Environment(\.openURL) private var openURL
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @State private var track: Track?
    @State private var location: CLLocation?
    @State private var locating = true

    /// Further than this from the start and you're offered directions to it.
    static let nearStart = 200.0

    private var start: CLLocationCoordinate2D? {
        track?.drawableSegments.first?.first?.coordinate
    }

    private var distanceToStart: Double? {
        guard let location, let start else { return nil }
        return CLLocation(latitude: start.latitude, longitude: start.longitude).distance(from: location)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if let track, !track.isEmpty {
                        TrackMap(track: track)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 300)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                HStack(spacing: 12) {
                    DetailTile(title: "DISTANCE",
                               value: units.distance(route.distance).formatted(.number.precision(.fractionLength(1))),
                               unit: units.distanceLabel)
                    if let gain = route.elevationGain {
                        DetailTile(title: "CLIMB",
                                   value: units.elevation(gain).formatted(.number.precision(.fractionLength(0))),
                                   unit: units.elevationLabel)
                    }
                }

                startSection
            }
            .padding()
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { track = await library.loadTrack(for: route) }
        .task {
            location = await CurrentLocation.fetch()
            locating = false
        }
    }

    @ViewBuilder
    private var startSection: some View {
        if let distance = distanceToStart, distance > Self.nearStart, let start {
            VStack(spacing: 12) {
                Label("The start is \(units.shortDistance(distance)) away", systemImage: "location.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Progress begins when you reach the route.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button("Apple Maps", systemImage: "map") {
                        if let url = MapLinks.appleDirections(to: start) { openURL(url) }
                    }
                    Button("Google Maps", systemImage: "map") {
                        if let url = MapLinks.googleDirections(to: start) { openURL(url) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                startButton("Start Anyway")
            }
        } else {
            VStack(spacing: 8) {
                startButton("Start Ride")
                if locating {
                    Text("Finding your location…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func startButton(_ title: String) -> some View {
        Button {
            ride.start(following: route, track: track)
        } label: {
            Label(title, systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.large)
        .disabled(track?.isEmpty ?? true)
    }
}

enum CurrentLocation {
    /// One reasonably accurate fix (within 100 m), or nil after `timeout`.
    static func fetch(timeout: Duration = .seconds(15)) async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy <= 100 {
                            return location
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
