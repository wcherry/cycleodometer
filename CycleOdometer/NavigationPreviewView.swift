import MapKit
import SwiftUI

/// Apple's cycling route to a place, with any alternatives to choose between, and Go.
struct NavigationPreviewView: View {
    var destination: Destination

    @Environment(RideTracker.self) private var ride
    @Environment(RecentDestinations.self) private var recents
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @State private var routes: [DirectionsRoute] = []
    @State private var selected = 0
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                map
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                if loading {
                    ProgressView("Finding a cycling route…")
                        .padding()
                } else if let failure {
                    ContentUnavailableView("No Route", systemImage: "bicycle", description: Text(failure))
                } else {
                    VStack(spacing: 8) {
                        ForEach(routes.indices, id: \.self) { index in
                            RouteOption(route: routes[index], units: units, isSelected: index == selected)
                                .onTapGesture { selected = index }
                        }
                    }

                    Button {
                        recents.add(destination)
                        ride.startNavigation(to: destination, along: routes[selected])
                    } label: {
                        Label("Go", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }
            }
            .padding()
        }
        .navigationTitle(destination.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await plan() }
    }

    private var map: some View {
        Map(initialPosition: .automatic) {
            // The chosen route on top, in blue; alternatives in grey.
            ForEach(routes.indices.filter { $0 != selected }, id: \.self) { index in
                MapPolyline(coordinates: routes[index].coordinates)
                    .stroke(Color.gray, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if routes.indices.contains(selected) {
                MapPolyline(coordinates: routes[selected].coordinates)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            Marker(destination.name, systemImage: "mappin", coordinate: destination.coordinate)
                .tint(.red)
            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // Reframe once the routes arrive.
        .id(routes.count)
    }

    private func plan() async {
        guard let here = await CurrentLocation.fetch() else {
            failure = "Your location isn't available yet."
            loading = false
            return
        }
        do {
            routes = try await MapKitDirections().cyclingRoutes(from: here.coordinate, to: destination.coordinate,
                                                                alternatives: true)
        } catch {
            failure = "Apple Maps has no cycling directions to this place, or you're offline."
        }
        loading = false
    }
}

private struct RouteOption: View {
    var route: DirectionsRoute
    var units: UnitSystem
    var isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Navigation.timeLeftText(route.expectedTravelTime).replacingOccurrences(of: " left", with: ""))
                    .font(.title3.weight(.bold))
                Text(route.name.isEmpty ? "Cycling route" : "via \(route.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(units.distance(route.distance).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel)")
                .font(.headline)
                .monospacedDigit()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? .green : .secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(isSelected ? 0.12 : 0.06)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
