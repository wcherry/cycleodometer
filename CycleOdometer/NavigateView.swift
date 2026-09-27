import MapKit
import SwiftUI

/// Navigate To…: search for a place (with suggestions as you type), pick a recent
/// destination, or drop a pin. Choosing one shows the route preview.
struct NavigateView: View {
    @Environment(RecentDestinations.self) private var recents
    @Environment(\.dismiss) private var dismiss
    @State private var search = PlaceSearch()
    @State private var chosen: Destination?
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            List {
                if search.query.isEmpty {
                    Section {
                        NavigationLink {
                            DropPinView { chosen = $0 }
                        } label: {
                            Label("Drop a Pin", systemImage: "mappin.and.ellipse")
                        }
                    }
                    if !recents.items.isEmpty {
                        Section {
                            ForEach(recents.items) { place in
                                Button {
                                    chosen = place
                                } label: {
                                    PlaceRow(name: place.name, subtitle: place.subtitle, systemImage: "clock")
                                }
                                .tint(.primary)
                            }
                        } header: {
                            HStack {
                                Text("Recent")
                                Spacer()
                                Button("Clear") { recents.clear() }
                                    .font(.subheadline)
                            }
                        }
                    }
                } else {
                    ForEach(search.suggestions, id: \.self) { suggestion in
                        Button {
                            Task { await choose(suggestion) }
                        } label: {
                            PlaceRow(name: suggestion.title,
                                     subtitle: suggestion.subtitle.isEmpty ? nil : suggestion.subtitle,
                                     systemImage: "mappin.circle.fill")
                        }
                        .tint(.primary)
                    }
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a place")
            .navigationTitle("Navigate To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $chosen) { place in
                NavigationPreviewView(destination: place)
            }
            .alert("Couldn't Find That Place", isPresented: Binding(
                get: { searchError != nil }, set: { if !$0 { searchError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(searchError ?? "")
            }
            .task {
                // Nearby suggestions first.
                if let here = await CurrentLocation.fetch(timeout: .seconds(5)) {
                    search.near(here.coordinate)
                }
            }
        }
    }

    /// Turns a suggestion into a place with a location.
    private func choose(_ suggestion: MKLocalSearchCompletion) async {
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start()
            guard let item = response.mapItems.first else { throw MapKitDirections.NoRoute() }
            chosen = Destination(name: item.name ?? suggestion.title,
                                 subtitle: item.address?.shortAddress ?? (suggestion.subtitle.isEmpty ? nil : suggestion.subtitle),
                                 coordinate: item.location.coordinate)
        } catch {
            searchError = "Check your connection and try again."
        }
    }
}

private struct PlaceRow: View {
    var name: String
    var subtitle: String?
    var systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Suggestions as you type, from MapKit's search completer.
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Prefer places near here.
    func near(_ coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}

/// Tap the map to place a pin, then navigate there.
private struct DropPinView: View {
    var onChoose: (Destination) -> Void

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var pin: CLLocationCoordinate2D?
    @State private var naming = false

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()
                if let pin {
                    Marker("Dropped Pin", systemImage: "mappin", coordinate: pin)
                        .tint(.red)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .onTapGesture { point in
                pin = proxy.convert(point, from: .local)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await choose() }
            } label: {
                Label(pin == nil ? "Tap the map to drop a pin" : "Navigate Here",
                      systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(pin == nil || naming)
            .padding()
        }
        .navigationTitle("Drop a Pin")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Names the pin after its address when Apple knows it.
    private func choose() async {
        guard let pin else { return }
        naming = true
        defer { naming = false }
        let location = CLLocation(latitude: pin.latitude, longitude: pin.longitude)
        let item = try? await MKReverseGeocodingRequest(location: location)?.mapItems.first
        let address = item?.address?.shortAddress ?? item?.name
        onChoose(Destination(name: address.flatMap { $0.split(separator: ",").first.map(String.init) } ?? "Dropped Pin",
                             subtitle: address, coordinate: pin))
    }
}
