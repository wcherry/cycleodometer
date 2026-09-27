import CoreLocation
import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

/// A named route, saved from a ride (or, later, imported from a GPX file).
struct SavedRoute: Codable, Identifiable, Hashable {
    enum Source: Codable, Hashable {
        case ride(id: UUID, date: Date)
        case imported
    }

    var id = UUID()
    var name: String
    var createdAt: Date
    var source: Source
    /// In metres.
    var distance: Double
    /// Total climb in metres, when the route has elevations.
    var elevationGain: Double?
    /// Street names found for the route's turns, saved so each is looked up once.
    var turnNames: TurnNames?
}

struct TurnNames: Codable, Hashable {
    /// How many turns the route had when named; if turn detection ever changes,
    /// a different count means the names no longer line up and are discarded.
    var turnCount: Int
    /// One per turn looked up so far, in order; "" where there was no name.
    var names: [String]
}

/// Saved routes, newest first. Each route's geometry is a GPX file in
/// `routes/<route id>.gpx`, listed in `routes/index.json`.
///
/// A route owns its own copy of the geometry, so it outlives the ride it came from.
@Observable
final class RouteLibrary {
    private(set) var routes: [SavedRoute] = []

    @ObservationIgnored private let directory: URL
    private var indexURL: URL { directory.appending(path: "index.json") }

    /// Routes are stored simplified to about this many metres: plenty for following
    /// one, and a 100 km route stays at a few thousand points.
    static let storageTolerance = 3.0

    init(directory: URL = RouteLibrary.defaultDirectory) {
        self.directory = directory
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([SavedRoute].self, from: data) {
            routes = saved
        }
    }

    /// Saves `track` as a new route. Times and speeds are dropped: a route is a path,
    /// and a shared file shouldn't say when you rode it.
    @discardableResult
    func add(name: String, track: Track, source: SavedRoute.Source) -> SavedRoute? {
        guard !track.isEmpty else { return nil }
        let route = SavedRoute(
            name: name,
            createdAt: .now,
            source: source,
            distance: track.distance,
            elevationGain: track.elevationGain()
        )
        let stored = Track(segments: track.drawableSegments.map { segment in
            Simplify.points(segment, tolerance: Self.storageTolerance).map {
                TrackPoint(latitude: $0.latitude, longitude: $0.longitude, elevation: $0.elevation)
            }
        })
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(GPX.document(for: stored, name: name).utf8).write(to: fileURL(for: route), options: .atomic)
        } catch {
            return nil
        }
        routes.insert(route, at: 0)
        save()
        return route
    }

    enum ImportError: LocalizedError, Equatable {
        case tooLarge
        case unreadable
        case notGPX
        case noRoute

        var errorDescription: String? {
            switch self {
            case .tooLarge: "This file is over 20 MB, which is too large for one route."
            case .unreadable: "The file couldn't be read."
            case .notGPX: "This isn't a GPX file Cycle can read."
            case .noRoute: "This file has no route in it."
            }
        }
    }

    static let importSizeLimit = 20 * 1_024 * 1_024

    /// Imports a GPX file as a new route, named from the file's `<name>` or, failing
    /// that, its file name. Works with files from the file picker (security-scoped)
    /// and ones handed over by other apps.
    @discardableResult
    func importGPX(from url: URL) throws -> SavedRoute {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.importSizeLimit {
            throw ImportError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }

        let parsed: (name: String?, track: Track)
        do {
            parsed = try GPX.parse(data)
        } catch GPX.ParseError.noTrack {
            throw ImportError.noRoute
        } catch {
            throw ImportError.notGPX
        }
        let name = parsed.name ?? url.deletingPathExtension().lastPathComponent
        guard let route = add(name: name, track: parsed.track, source: .imported) else {
            throw ImportError.unreadable
        }
        return route
    }

    func rename(_ route: SavedRoute, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index].name = name
        save()
    }

    func saveTurnNames(_ names: TurnNames, for route: SavedRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index].turnNames = names
        save()
    }

    func delete(_ route: SavedRoute) {
        try? FileManager.default.removeItem(at: fileURL(for: route))
        routes.removeAll { $0.id == route.id }
        save()
    }

    /// The route saved from a given ride, if there is one.
    func route(fromRide rideID: UUID) -> SavedRoute? {
        routes.first {
            if case .ride(let id, _) = $0.source { id == rideID } else { false }
        }
    }

    func loadTrack(for route: SavedRoute) async -> Track? {
        let url = fileURL(for: route)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? GPX.parse(data).track
        }.value
    }

    func fileURL(for route: SavedRoute) -> URL {
        directory.appending(path: "\(route.id.uuidString).gpx")
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(routes).write(to: indexURL, options: .atomic)
        } catch {
            // As with ride history: not worth interrupting anyone over.
        }
    }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "routes", directoryHint: .isDirectory)
    }
}

extension UTType {
    /// Declared in Info.plist (`UTImportedTypeDeclarations`).
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// A route as a `.gpx` file for the share sheet, named after the route and written
/// only when something actually asks for it.
struct RouteGPXFile: Transferable {
    var route: SavedRoute
    var sourceURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { file in
            let data = try Data(contentsOf: file.sourceURL)
            let track = try GPX.parse(data).track
            // Rewritten rather than copied, so a renamed route carries its new name.
            let url = FileManager.default.temporaryDirectory
                .appending(path: "\(file.fileName).gpx")
            try Data(GPX.document(for: track, name: file.route.name).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    private var fileName: String {
        let cleaned = route.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return cleaned.isEmpty ? "Route" : cleaned
    }
}

/// Links that open a route, or the way to it, in another app: Google Maps, Apple Maps
/// or Citymapper.
///
/// Neither app can import a track, so these are approximations: see "Platform limits"
/// in docs/features/routes-and-maps.md.
enum MapLinks {
    /// Google allows 9 waypoints in its app, but only 3 when the link opens in a
    /// mobile browser (Google Maps not installed).
    static let googleAppWaypointLimit = 9
    static let googleBrowserWaypointLimit = 3

    /// Cycling directions in Google Maps from the route's start to its finish,
    /// steered through up to `maxWaypoints` of its most significant turns.
    static func googleDirections(along track: Track, maxWaypoints: Int) -> URL? {
        let points = track.drawableSegments.joined().map(\.coordinate)
        guard let start = points.first, let finish = points.last else { return nil }
        let waypoints = sampleWaypoints(points, maxCount: maxWaypoints)
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: text(start)),
            URLQueryItem(name: "destination", value: text(finish)),
            URLQueryItem(name: "travelmode", value: "bicycling"),
        ]
        if !waypoints.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: waypoints.map(text).joined(separator: "|")))
        }
        return url("https://www.google.com/maps/dir/", items)
    }

    /// Cycling directions in Google Maps from wherever you are to `destination`.
    static func googleDirections(to destination: CLLocationCoordinate2D) -> URL? {
        url("https://www.google.com/maps/dir/", [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: text(destination)),
            URLQueryItem(name: "travelmode", value: "bicycling"),
        ])
    }

    /// Cycling directions in Apple Maps from wherever you are to `destination`
    /// (unified Maps URL).
    static func appleDirections(to destination: CLLocationCoordinate2D) -> URL? {
        url("https://maps.apple.com/directions", [
            URLQueryItem(name: "destination", value: text(destination)),
            URLQueryItem(name: "mode", value: "cycling"),
        ])
    }

    /// Directions in Citymapper from wherever you are to `destination`.
    static func citymapperDirections(to destination: CLLocationCoordinate2D, name: String?) -> URL? {
        var items = [URLQueryItem(name: "endcoord", value: text(destination))]
        if let name { items.append(URLQueryItem(name: "endname", value: name)) }
        return url("citymapper://directions", items)
    }

    /// Up to `maxCount` interior points of the route, chosen at its biggest turns
    /// rather than evenly spaced: Douglas–Peucker with a tolerance that grows until
    /// few enough points survive. Evenly spaced points would miss the corners where
    /// Google would otherwise take a different road.
    static func sampleWaypoints(_ points: [CLLocationCoordinate2D], maxCount: Int) -> [CLLocationCoordinate2D] {
        guard points.count > 2, maxCount > 0 else { return [] }
        var tolerance = 5.0
        while true {
            let kept = Simplify.indices(of: points, tolerance: tolerance)
            if kept.count - 2 <= maxCount {
                return kept.dropFirst().dropLast().map { points[$0] }
            }
            tolerance *= 1.5
        }
    }

    private static func text(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
    }

    private static func url(_ base: String, _ items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items
        // URLComponents leaves "|" alone; Google documents it percent-encoded.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "|", with: "%7C")
        components.percentEncodedQuery = query
        return components.url
    }
}
