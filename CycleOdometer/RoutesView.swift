import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// The route library: every saved route, newest first.
///
/// From Ride History, a route opens its page. When `picking` (Ride a Route on the
/// start screen), it goes straight to starting a ride on it.
struct RoutesView: View {
    var picking = false

    @Environment(RouteLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Group {
            if library.routes.isEmpty {
                ContentUnavailableView {
                    Label("No Routes Yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("Open a ride in Ride History and tap Save as Route, or import a GPX file from another app.")
                } actions: {
                    Button("Import GPX…") { importing = true }
                        .buttonStyle(.bordered)
                }
            } else {
                List {
                    ForEach(library.routes) { route in
                        if picking {
                            NavigationLink {
                                RouteStartView(route: route)
                            } label: {
                                RouteRow(route: route, units: units)
                            }
                        } else {
                            NavigationLink(value: route) {
                                RouteRow(route: route, units: units)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { library.routes[$0] }.forEach(library.delete)
                    }
                }
            }
        }
        .navigationTitle(picking ? "Ride a Route" : "Routes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if picking {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Import GPX…", systemImage: "square.and.arrow.down") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml]) { result in
            do {
                try library.importGPX(from: result.get())
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't Import", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }
}

private struct RouteRow: View {
    var route: SavedRoute
    var units: UnitSystem

    @Environment(RouteLibrary.self) private var library
    @State private var track: Track?

    var body: some View {
        HStack(spacing: 14) {
            RouteShape(track: track)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 3) {
                Text(route.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(units.distance(route.distance).formatted(.number.precision(.fractionLength(1)))) \(units.distanceLabel) · \(route.sourceDescription)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .task { track = await library.loadTrack(for: route) }
    }
}

/// A route's outline, scaled to fit: a quick preview without the cost of a map.
private struct RouteShape: View {
    var track: Track?

    var body: some View {
        Canvas { context, size in
            guard let track, !track.isEmpty else { return }
            let segments = track.drawableSegments.map { $0.map(\.coordinate) }
            let all = segments.joined()
            let lats = all.map(\.latitude), lons = all.map(\.longitude)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }
            // Longitude degrees shrink away from the equator; correct so shapes aren't stretched.
            let xScale = cos((minLat + maxLat) / 2 * .pi / 180)
            let width = max((maxLon - minLon) * xScale, 1e-9), height = max(maxLat - minLat, 1e-9)
            let inset = 6.0
            let scale = min((size.width - 2 * inset) / width, (size.height - 2 * inset) / height)
            let xOffset = (size.width - width * scale) / 2, yOffset = (size.height - height * scale) / 2

            var path = Path()
            for segment in segments {
                for (i, c) in segment.enumerated() {
                    let point = CGPoint(x: xOffset + (c.longitude - minLon) * xScale * scale,
                                        y: yOffset + (maxLat - c.latitude) * scale)
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct RouteDetailView: View {
    var route: SavedRoute

    @Environment(RouteLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(UnitSystem.storageKey) private var units = UnitSystem.imperial
    @State private var track: Track?
    @State private var isLoading = true
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    /// The current copy from the library, so a rename shows straight away.
    private var current: SavedRoute {
        library.routes.first { $0.id == route.id } ?? route
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let track, !track.isEmpty {
                        TrackMap(track: track)
                    } else {
                        ContentUnavailableView("Route Unavailable", systemImage: "map",
                                               description: Text("This route's file couldn't be read."))
                    }
                }
                .frame(height: 380)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 20))

                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        DetailTile(title: "DISTANCE",
                                   value: units.distance(current.distance).formatted(.number.precision(.fractionLength(1))),
                                   unit: units.distanceLabel)
                        if let gain = current.elevationGain {
                            DetailTile(title: "CLIMB",
                                       value: units.elevation(gain).formatted(.number.precision(.fractionLength(0))),
                                       unit: units.elevationLabel)
                        }
                    }
                }

                NavigationLink {
                    RouteStartView(route: current)
                } label: {
                    Label("Ride This Route", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                Text(current.sourceDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Shared routes show exactly where they start and finish.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { shareMenu }
            ToolbarItem(placement: .secondaryAction) {
                Button("Rename", systemImage: "pencil") {
                    newName = current.name
                    renaming = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .alert("Rename Route", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { library.rename(current, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(current.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Route", role: .destructive) {
                library.delete(current)
                dismiss()
            }
        } message: {
            Text("The ride it came from, if it's still in Ride History, isn't affected.")
        }
        .task {
            track = await library.loadTrack(for: route)
            isLoading = false
        }
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: RouteGPXFile(route: current, sourceURL: library.fileURL(for: current)),
                      preview: SharePreview(current.name)) {
                Label("Share GPX File…", systemImage: "doc")
            }

            if let track {
                Button {
                    let limit = UIApplication.shared.canOpenURL(URL(string: "comgooglemaps://")!)
                        ? MapLinks.googleAppWaypointLimit
                        : MapLinks.googleBrowserWaypointLimit
                    if let url = MapLinks.googleDirections(along: track, maxWaypoints: limit) {
                        openURL(url)
                    }
                } label: {
                    Label("Open in Google Maps (approximate)", systemImage: "arrow.triangle.turn.up.right.diamond")
                }

                if let start = track.drawableSegments.first?.first?.coordinate {
                    let app = DirectionsApp.preferred()
                    Button {
                        if let url = app.directions(to: start, name: "Start of \(current.name)") { openURL(url) }
                    } label: {
                        Label("Directions to Start in \(app.name)", systemImage: "map")
                    }
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

extension SavedRoute {
    var sourceDescription: String {
        switch source {
        case .ride(_, let date):
            "From ride on \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        case .imported:
            "Imported"
        }
    }
}
